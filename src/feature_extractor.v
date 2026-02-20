/*
 * NanoTrade Feature Extractor
 * ==============================
 * Converts the raw market data stream into a 128-bit feature vector
 * (16 × 8-bit unsigned values) consumed by the ML inference engine.
 *
 * Feature vector layout (matches Python training script):
 *   [0]  price_change_1s       |Δprice| over last 8 cycles,  clipped 0..255
 *   [1]  price_change_10s      |Δprice| over last 32 cycles, clipped 0..255
 *   [2]  price_change_60s      |Δprice| over 64-cycle window,clipped 0..255
 *   [3]  volume_ratio          cur_vol/(avg_vol/64), clipped 0..255
 *   [4]  spread_pct            zero orders on one side → 255, else 0..128
 *   [5]  buy_sell_imbalance    buys/(buys+sells)*255, clipped 0..255
 *   [6]  volatility            MAD scaled × 4, clipped 0..255
 *   [7]  order_arrival_rate    buy+sell count per 256-cy window, clipped
 *   [8]  cancel_rate           not available on TT I/O → 0 (safe fallback)
 *   [9]  buy_depth             buy_order_count × 16, clipped 0..255
 *   [10] sell_depth            sell_order_count × 16, clipped 0..255
 *   [11] time_since_trade      cycles since last match, >>4, clipped 0..255
 *   [12] avg_order_lifespan    0 (safe: no cancel tracking on TT)
 *   [13] trade_frequency       matches per 256-cycle window × 4, clipped
 *   [14] price_momentum        sign + magnitude of 2nd derivative, 0..255
 *   [15] reserved              128 (= 0 in signed)
 *
 * Outputs feature_valid for 1 cycle every 256 clock cycles (feature rate),
 * which triggers a new ML inference.
 */

`default_nettype none



module feature_extractor (
    input  wire        clk,
    input  wire        rst_n,

    // Raw inputs (same encoding as anomaly_detector)
    input  wire [1:0]  input_type,    // 00=price,01=vol,10=buy,11=sell
    input  wire [11:0] price_data,    // 12-bit price
    input  wire [11:0] volume_data,   // 12-bit volume
    input  wire        match_valid,   // order matched this cycle

    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  match_price, /* verilator lint_on UNUSEDSIGNAL */   // matched price


    // Output feature vector
    output reg  [127:0] features,      // 16 × 8-bit
    output reg          feature_valid  // pulse every 256 cycles
);

    wire is_price  = (input_type == 2'b00);
    wire is_volume = (input_type == 2'b01);
    wire is_buy    = (input_type == 2'b10);
    wire is_sell   = (input_type == 2'b11);

    // ---------------------------------------------------------------
    // History registers
    // ---------------------------------------------------------------

    // 8-entry price ring buffer (short window)
    reg [11:0] price_s [0:7];   // short window
    reg [11:0] price_m [0:31];  // medium window
    reg [11:0] price_l [0:63];  // long window
    reg [2:0]  ptr_s;
    reg [4:0]  ptr_m;
    reg [5:0]  ptr_l;

    // Running price sum for average
    reg [14:0] price_sum8;    // 8-entry, 12-bit → 15-bit
    reg [11:0] price_mad;

    // Volume
    reg [11:0] cur_vol;
    reg [14:0] vol_sum8;
    reg [2:0]  vol_ptr;
    reg [11:0] vol_hist [0:7];
    reg [11:0] vol_avg;

    // Order pressure
    reg [7:0]  buy_count;
    reg [7:0]  sell_count;
    reg [7:0]  match_count;

    // Previous prices for momentum
    reg [11:0] price_prev1;
    reg [11:0] price_prev2;
    reg [11:0] cur_price;

    // Time since last match
    reg [15:0] trade_timer;

    // Window timer for feature emission
    reg [7:0]  window_cnt;
    reg [7:0]  match_rate;

    integer i;

    // Hoisted from unnamed block (Verilog-2001 compatibility)


    // ---------------------------------------------------------------
    // Sequential updates
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr_s       <= 3'd0;
            ptr_m       <= 5'd0;
            ptr_l       <= 6'd0;
            vol_ptr     <= 3'd0;
            price_sum8  <= 15'd800;   // default avg = 100
            price_mad   <= 12'd5;
            vol_sum8    <= 15'd800;
            vol_avg     <= 12'd100;
            cur_vol     <= 12'd100;
            cur_price   <= 12'd100;
            price_prev1 <= 12'd100;
            price_prev2 <= 12'd100;
            buy_count   <= 8'd0;
            sell_count  <= 8'd0;
            match_count <= 8'd0;
            trade_timer <= 16'd0;
            window_cnt  <= 8'd0;
            match_rate  <= 8'd0;
            feature_valid <= 1'b0;

            for (i = 0; i < 8;  i = i + 1) price_s[i]   <= 12'd100;
            for (i = 0; i < 32; i = i + 1) price_m[i]   <= 12'd100;
            for (i = 0; i < 64; i = i + 1) price_l[i]   <= 12'd100;
            for (i = 0; i < 8;  i = i + 1) vol_hist[i]  <= 12'd100;

        end else begin
            feature_valid <= 1'b0;

            // --- Price update ---
            if (is_price) begin
                price_prev2  <= price_prev1;
                price_prev1  <= cur_price;
                cur_price    <= price_data;

                // Short ring buffer (8 entries)
                price_sum8          <= price_sum8 - {3'd0, price_s[ptr_s]} + {3'd0, price_data};
                price_s[ptr_s]      <= price_data;
                ptr_s               <= ptr_s + 3'd1;

                // Medium ring (32 entries) — just store
                price_m[ptr_m] <= price_data;
                ptr_m          <= ptr_m + 5'd1;

                // Long ring (64 entries)
                price_l[ptr_l] <= price_data;
                ptr_l          <= ptr_l + 6'd1;

                // Update MAD (inlined to avoid blocking assignments in sequential block)
                // EMA of MAD: new_mad = (7*mad + delta) / 8
                price_mad <= (price_mad * 7 +
                              ((price_data > price_sum8[14:3]) ?
                               (price_data - price_sum8[14:3]) :
                               (price_sum8[14:3] - price_data))) >> 3;
            end

            // --- Volume update ---
            if (is_volume) begin
                cur_vol             <= volume_data;
                vol_sum8            <= vol_sum8 - {3'd0, vol_hist[vol_ptr]} + {3'd0, volume_data};
                vol_hist[vol_ptr]   <= volume_data;
                vol_ptr             <= vol_ptr + 3'd1;
                vol_avg             <= vol_sum8[14:3];
            end

            // --- Order pressure ---
            if (is_buy)
                buy_count  <= (buy_count  < 8'hFF) ? buy_count  + 8'd1 : 8'hFF;
            if (is_sell)
                sell_count <= (sell_count < 8'hFF) ? sell_count + 8'd1 : 8'hFF;

            // --- Match tracking ---
            if (match_valid) begin
                match_count <= (match_count < 8'hFF) ? match_count + 8'd1 : 8'hFF;
                trade_timer <= 16'd0;
            end else begin
                trade_timer <= (trade_timer < 16'hFFFF) ? trade_timer + 16'd1 : 16'hFFFF;
            end

            // --- Window: emit features every 256 cycles ---
            window_cnt <= window_cnt + 8'd1;
            if (window_cnt == 8'hFF) begin
                match_rate  <= match_count;
                match_count <= 8'd0;
                // Slow decay on order counts
                buy_count   <= buy_count  >> 1;
                sell_count  <= sell_count >> 1;

                // ------------------------------------------
                // Compute and emit feature vector
                // ------------------------------------------
                feature_valid <= 1'b1;

                // [0] price_change_1s: |cur - oldest_short|
                features[0*8 +: 8] <= clip8(
                    price_delta(cur_price, price_s[ptr_s]) );

                // [1] price_change_10s: |cur - oldest_medium|
                features[1*8 +: 8] <= clip8(
                    price_delta(cur_price, price_m[ptr_m]) );

                // [2] price_change_60s: |cur - oldest_long|
                features[2*8 +: 8] <= clip8(
                    price_delta(cur_price, price_l[ptr_l]) );

                // [3] volume_ratio: cur_vol / (vol_avg/64) — scales 1x→64
                features[3*8 +: 8] <= vol_ratio_byte(cur_vol, vol_avg);

                // [4] spread_pct: zero depth on either side = 255
                features[4*8 +: 8] <= spread_byte(buy_count, sell_count);

                // [5] buy_sell_imbalance: buys/(buys+sells) * 255
                features[5*8 +: 8] <= imbalance_byte(buy_count, sell_count);

                // [6] volatility: MAD * 4 clipped
                features[6*8 +: 8] <= clip8({price_mad, 2'b00});

                // [7] order_arrival_rate: (buy+sell) count, clipped
                features[7*8 +: 8] <= clip8_16(
                    {8'd0, buy_count} + {8'd0, sell_count});

                // [8] cancel_rate: 0 (not tracked on TT I/O)
                features[8*8 +: 8] <= 8'd0;

                // [9] buy_depth: buy_count * 16
                features[9*8 +: 8]  <= clip8({buy_count[3:0], 4'h0});

                // [10] sell_depth: sell_count * 16
                features[10*8 +: 8] <= clip8({sell_count[3:0], 4'h0});

                // [11] time_since_trade: timer >> 4
                features[11*8 +: 8] <= trade_timer[11:4];

                // [12] avg_order_lifespan: 0 (no cancel tracking)
                features[12*8 +: 8] <= 8'd200;   // healthy default

                // [13] trade_frequency: match_rate * 4
                features[13*8 +: 8] <= clip8({match_rate, 2'b00});

                // [14] price_momentum: 2nd derivative direction + magnitude
                features[14*8 +: 8] <= momentum_byte(cur_price, price_prev1, price_prev2);

                // [15] reserved
                features[15*8 +: 8] <= 8'd128;
            end
        end
    end

    // ---------------------------------------------------------------
    // Helper functions (synthesizable)
    // ---------------------------------------------------------------

    // Absolute delta between two 12-bit prices, clipped to 8 bits
    function automatic [7:0] price_delta;
        input [11:0] a, b;
        reg [11:0] d;
        begin
            d = (a > b) ? (a - b) : (b - a);
            price_delta = (d > 12'd255) ? 8'd255 : d[7:0];
        end
    endfunction

    // Clip 12-bit to 8-bit
    function automatic [7:0] clip8;
        input [11:0] x;
        begin
            clip8 = (x > 12'd255) ? 8'd255 : x[7:0];
        end
    endfunction

    // Clip 16-bit to 8-bit
    function automatic [7:0] clip8_16;
        input [15:0] x;
        begin
            clip8_16 = (x > 16'd255) ? 8'd255 : x[7:0];
        end
    endfunction

    // Volume ratio: cur / (avg/64) = cur*64/avg, clipped to 255
    function automatic [7:0] vol_ratio_byte;
        input [11:0] cur, avg;
        reg [19:0] vr_tmp;
        begin
            if (avg == 12'd0)
                vol_ratio_byte = 8'd64;
            else begin
                vr_tmp = ({8'd0, cur} * 20'd64) / avg;
                vol_ratio_byte = (vr_tmp > 20'd255) ? 8'd255 : vr_tmp[7:0];
            end
        end
    endfunction

    // Spread: 255 when one side empty, 0 when balanced
    function automatic [7:0] spread_byte;
        input [7:0] bids, asks;
        begin
            if (bids == 8'd0 || asks == 8'd0)
                spread_byte = 8'd255;
            else if (bids < 8'd3 || asks < 8'd3)
                spread_byte = 8'd128;
            else
                spread_byte = 8'd10;
        end
    endfunction

    // Imbalance: buys/(buys+sells) * 255
    function automatic [7:0] imbalance_byte;
        input [7:0] buys, sells;
        reg [15:0] ib_total, ib_num;
        begin
            ib_total = {8'd0, buys} + {8'd0, sells};
            if (ib_total == 16'd0)
                imbalance_byte = 8'd128;
            else begin
                ib_num = ({8'd0, buys} * 16'd255) / ib_total;
                imbalance_byte = (ib_num > 16'd255) ? 8'd255 : ib_num[7:0];
            end
        end
    endfunction

    // Momentum: encode 2nd derivative into 0..255
    // If accelerating up → > 128, down → < 128, flat → 128
    function automatic [7:0] momentum_byte;
        input [11:0] p0, p1, p2;
        reg signed [12:0] mb_mom;
        begin
            mb_mom = ($signed({1'b0, p0}) - $signed({1'b0, p1})) - ($signed({1'b0, p1}) - $signed({1'b0, p2}));
            if (mb_mom > 13'sd63)
                momentum_byte = 8'd255;
            else if (mb_mom < -13'sd63)
                momentum_byte = 8'd0;
            else
                momentum_byte = 8'd128 + mb_mom[7:0];
        end
    endfunction

endmodule
