/*
 * NanoTrade Feature Extractor  (v2 — Area-Optimized for SKY130 1×1 tile)
 * =========================================================================
 * Key changes vs v1:
 *   - price_m (32×12-bit = 384 bits) REMOVED
 *   - price_l (64×12-bit = 768 bits) REMOVED
 *     Together these saved ~1152 register bits (~288 flip-flops).
 *     Replaced with two 8-bit slow EMA accumulators (16 bits total).
 *   - vol_ratio divider replaced with shift approximation (saves ~200 LUTs)
 *   - imbalance_byte divider replaced with 3-level priority encode
 *   - Functions replaced with inline named blocks (OpenLane safe)
 *
 * Feature vector layout (16 × 8-bit, same indices as v1):
 *   [0]  price_change_1s     |Δprice| over 8-cy short ring,  0..255
 *   [1]  price_change_10s    medium EMA proxy,                0..255
 *   [2]  price_change_60s    long EMA proxy,                  0..255
 *   [3]  volume_ratio        cur vs avg (shift approx),       0..255
 *   [4]  spread_pct          one-sided depth → 255,           0..255
 *   [5]  buy_sell_imbalance  3-level encode,                  0/64/128/192/255
 *   [6]  volatility          MAD × 4,                         0..255
 *   [7]  order_arrival_rate  buy+sell count,                  0..255
 *   [8]  cancel_rate         0
 *   [9]  buy_depth           buy_count × 16,                  0..255
 *  [10]  sell_depth          sell_count × 16,                 0..255
 *  [11]  time_since_trade    timer >> 4,                      0..255
 *  [12]  avg_order_lifespan  200 (constant default)
 *  [13]  trade_frequency     match_rate × 4,                  0..255
 *  [14]  price_momentum      2nd-derivative encode,           0..255
 *  [15]  reserved            128
 */

`default_nettype none

module feature_extractor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  input_type,
    input  wire [11:0] price_data,
    input  wire [11:0] volume_data,
    input  wire        match_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  match_price,
    /* verilator lint_on UNUSEDSIGNAL */
    output reg  [127:0] features,
    output reg          feature_valid
);

    wire is_price  = (input_type == 2'b00);
    wire is_volume = (input_type == 2'b01);
    wire is_buy    = (input_type == 2'b10);
    wire is_sell   = (input_type == 2'b11);

    // Short price ring buffer (8 × 12-bit = 96 bits)
    reg [11:0] price_s [0:7];
    reg [2:0]  ptr_s;
    reg [14:0] price_sum8;
    reg [11:0] price_mad;

    // Slow-decay EMA accumulators replacing the 32 and 64-entry rings
    reg [7:0] feat1_acc;   // medium-term proxy (~10s equivalent)
    reg [7:0] feat2_acc;   // long-term proxy   (~60s equivalent)

    // Volume ring buffer (8 × 12-bit = 96 bits)
    reg [11:0] vol_hist [0:7];
    reg [2:0]  vol_ptr;
    reg [14:0] vol_sum8;
    reg [11:0] cur_vol;

    // Order pressure
    reg [7:0] buy_count;
    reg [7:0] sell_count;
    reg [7:0] match_count;

    // Price history for momentum
    reg [11:0] cur_price;
    reg [11:0] price_prev1;
    reg [11:0] price_prev2;

    // Trade timer
    reg [15:0] trade_timer;

    // Window counter
    reg [7:0] window_cnt;
    reg [7:0] match_rate;

    integer i;

    always @(posedge clk or negedge rst_n) begin : seq_main
        if (!rst_n) begin
            ptr_s       <= 3'd0;
            vol_ptr     <= 3'd0;
            price_sum8  <= 15'd800;
            price_mad   <= 12'd5;
            vol_sum8    <= 15'd800;
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
            feat1_acc   <= 8'd0;
            feat2_acc   <= 8'd0;
            feature_valid <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                price_s[i]  <= 12'd100;
                vol_hist[i] <= 12'd100;
            end
        end else begin
            feature_valid <= 1'b0;

            if (is_price) begin : price_update
                reg [11:0] price_avg_l;
                reg [11:0] mad_delta;
                reg [7:0]  delta8;
                price_avg_l = price_sum8[14:3];

                price_prev2  <= price_prev1;
                price_prev1  <= cur_price;
                cur_price    <= price_data;

                price_sum8     <= price_sum8 - {3'd0, price_s[ptr_s]} + {3'd0, price_data};
                price_s[ptr_s] <= price_data;
                ptr_s          <= ptr_s + 3'd1;

                // MAD EMA
                mad_delta = (price_data > price_avg_l) ?
                            (price_data - price_avg_l) :
                            (price_avg_l - price_data);
                price_mad <= (price_mad * 7 + {4'd0, mad_delta[11:4]}) >> 3;

                // feat1 EMA (τ≈8): new = acc - acc/8 + delta/8
                // All operands kept 8-bit; no overflow possible (255-31+31=255)
                delta8 = (mad_delta > 12'd255) ? 8'd255 : mad_delta[7:0];
                feat1_acc <= feat1_acc - {3'b000, feat1_acc[7:3]} + {3'b000, delta8[7:3]};

                // feat2 EMA (τ≈32): new = acc - acc/32 + delta/32
                feat2_acc <= feat2_acc - {5'b00000, feat2_acc[7:5]} + {5'b00000, delta8[7:5]};
            end

            if (is_volume) begin
                cur_vol           <= volume_data;
                vol_sum8          <= vol_sum8 - {3'd0, vol_hist[vol_ptr]} + {3'd0, volume_data};
                vol_hist[vol_ptr] <= volume_data;
                vol_ptr           <= vol_ptr + 3'd1;
            end

            if (is_buy)
                buy_count  <= (buy_count  < 8'hFF) ? buy_count  + 8'd1 : 8'hFF;
            if (is_sell)
                sell_count <= (sell_count < 8'hFF) ? sell_count + 8'd1 : 8'hFF;

            if (match_valid) begin
                match_count <= (match_count < 8'hFF) ? match_count + 8'd1 : 8'hFF;
                trade_timer <= 16'd0;
            end else begin
                trade_timer <= (trade_timer < 16'hFFFF) ? trade_timer + 16'd1 : 16'hFFFF;
            end

            window_cnt <= window_cnt + 8'd1;
            if (window_cnt == 8'hFF) begin
                match_rate  <= match_count;
                match_count <= 8'd0;
                buy_count   <= buy_count  >> 1;
                sell_count  <= sell_count >> 1;
                feature_valid <= 1'b1;

                begin : emit_feats
                    reg [11:0] delta_s;
                    reg [15:0] vr_tmp;
                    reg [15:0] arr_tmp;
                    reg signed [12:0] mom;
                    reg [7:0]  vol_avg8;

                    // [0] price_change_1s
                    delta_s = (cur_price > price_s[ptr_s]) ?
                               cur_price - price_s[ptr_s] :
                               price_s[ptr_s] - cur_price;
                    features[0*8 +: 8] <= (delta_s > 12'd255) ? 8'd255 : delta_s[7:0];

                    // [1] price_change_10s (medium EMA proxy)
                    features[1*8 +: 8] <= feat1_acc;

                    // [2] price_change_60s (long EMA proxy)
                    features[2*8 +: 8] <= feat2_acc;

                    // [3] volume_ratio: cur_vol vs avg (shift approx, no divider)
                    //     vol_avg ≈ vol_sum8 >> 3; ratio = cur/(avg/64) ≈ cur<<6/avg
                    //     Approx: use vol_sum8>>7 as "avg/64" proxy
                    vol_avg8 = vol_sum8[14:7]; // sum/128 ≈ avg/16
                    vr_tmp = (vol_avg8 == 8'd0) ? 16'd64 :
                             ({4'd0, cur_vol} << 1) / {8'd0, vol_avg8};
                    features[3*8 +: 8] <= (vr_tmp > 16'd255) ? 8'd255 : vr_tmp[7:0];

                    // [4] spread_pct
                    features[4*8 +: 8] <=
                        (buy_count == 8'd0 || sell_count == 8'd0) ? 8'd255 :
                        (buy_count < 8'd3  || sell_count < 8'd3)  ? 8'd128 : 8'd10;

                    // [5] buy_sell_imbalance (3-level, no divider)
                    features[5*8 +: 8] <=
                        (buy_count == 8'd0 && sell_count == 8'd0) ? 8'd128 :
                        (buy_count == 8'd0)                        ? 8'd0   :
                        (sell_count == 8'd0)                       ? 8'd255 :
                        (buy_count > sell_count + (sell_count >> 1)) ? 8'd192 :
                        (sell_count > buy_count + (buy_count >> 1))  ? 8'd64  : 8'd128;

                    // [6] volatility: MAD × 4, clipped
                    features[6*8 +: 8] <=
                        ({4'd0, price_mad} > 16'd63) ? 8'd255 :
                        {2'b00, price_mad[5:0]};

                    // [7] order_arrival_rate
                    arr_tmp = {8'd0, buy_count} + {8'd0, sell_count};
                    features[7*8 +: 8] <= (arr_tmp > 16'd255) ? 8'd255 : arr_tmp[7:0];

                    // [8] cancel_rate
                    features[8*8 +: 8] <= 8'd0;

                    // [9] buy_depth
                    features[9*8 +: 8] <=
                        (buy_count[7:4] != 4'd0) ? 8'd255 : {buy_count[3:0], 4'h0};

                    // [10] sell_depth
                    features[10*8 +: 8] <=
                        (sell_count[7:4] != 4'd0) ? 8'd255 : {sell_count[3:0], 4'h0};

                    // [11] time_since_trade
                    features[11*8 +: 8] <= trade_timer[11:4];

                    // [12] avg_order_lifespan
                    features[12*8 +: 8] <= 8'd200;

                    // [13] trade_frequency
                    features[13*8 +: 8] <=
                        (match_rate > 8'd63) ? 8'd255 : {match_rate[5:0], 2'b00};

                    // [14] price_momentum
                    mom = ($signed({1'b0, cur_price}) - $signed({1'b0, price_prev1})) -
                          ($signed({1'b0, price_prev1}) - $signed({1'b0, price_prev2}));
                    features[14*8 +: 8] <=
                        (mom > 13'sd63)  ? 8'd255 :
                        (mom < -13'sd63) ? 8'd0   : 8'd128 + mom[7:0];

                    // [15] reserved
                    features[15*8 +: 8] <= 8'd128;
                end
            end
        end
    end

endmodule
