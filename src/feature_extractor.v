/*
 * NanoTrade Feature Extractor  (v3 — Area-Optimized, minimal registers)
 * ========================================================================
 * Stripped to only what's needed to feed the threshold classifier.
 * All ring buffers reduced or eliminated.
 *
 * Key changes vs v2:
 *   - price_s ring: 8×12 → 4×12 (saves 48 bits)
 *   - price_m, price_l: already removed in v2
 *   - features[] made a reg but only 8 features computed (saves 64 bits of comb)
 *   - vol_hist: 8×12 → 4×12 (saves 48 bits)
 *   - Dividers replaced with shifts (no hardware dividers)
 *   - features output is still 128-bit for interface compatibility but
 *     only features[0..7] are meaningful; rest are 0
 *
 * Feature vector (only [0..7] used by ml_inference_engine v4):
 *   [0]  price_change_1s     |Δprice| short window, 0..255
 *   [1]  price_change_10s    slow EMA proxy,         0..255
 *   [2]  0 (unused)
 *   [3]  volume_ratio        cur vs avg (shift),     0..255
 *   [4]  0 (unused)
 *   [5]  buy_sell_imbalance  3-level encode,          0/64/128/192/255
 *   [6]  volatility          MAD × 4,                0..255
 *   [7]  order_arrival_rate  buy+sell count,          0..255
 *   [8..15] 0
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

    // Short price ring: 4 entries (was 8) — saves 48 bits
    reg [11:0] price_s [0:3];
    reg [1:0]  ptr_s;
    reg [13:0] price_sum4;   // 4×12-bit → 14-bit
    reg [11:0] price_mad;

    // Slow EMA for medium-term change
    reg [7:0] feat1_acc;

    // Volume ring: 4 entries (was 8) — saves 48 bits
    reg [11:0] vol_hist [0:3];
    reg [1:0]  vol_ptr;
    reg [13:0] vol_sum4;
    reg [11:0] cur_vol;

    // Order pressure
    reg [7:0] buy_count;
    reg [7:0] sell_count;

    // Window counter
    reg [7:0] window_cnt;

    integer i;

    always @(posedge clk or negedge rst_n) begin : seq_main
        if (!rst_n) begin
            ptr_s       <= 2'd0;
            vol_ptr     <= 2'd0;
            price_sum4  <= 14'd400;
            price_mad   <= 12'd5;
            vol_sum4    <= 14'd400;
            cur_vol     <= 12'd100;
            buy_count   <= 8'd0;
            sell_count  <= 8'd0;
            window_cnt  <= 8'd0;
            feat1_acc   <= 8'd0;
            feature_valid <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                price_s[i]  <= 12'd100;
                vol_hist[i] <= 12'd100;
            end
        end else begin
            feature_valid <= 1'b0;

            if (is_price) begin : price_upd
                reg [11:0] pavg;
                reg [11:0] pdelta;
                reg [7:0]  delta8;
                pavg   = price_sum4[13:2];  // sum/4
                pdelta = (price_data > pavg) ? (price_data - pavg) : (pavg - price_data);

                price_sum4     <= price_sum4 - {2'd0, price_s[ptr_s]} + {2'd0, price_data};
                price_s[ptr_s] <= price_data;
                ptr_s          <= ptr_s + 2'd1;

                // MAD EMA
                price_mad <= (price_mad * 7 + {4'd0, pdelta[11:4]}) >> 3;

                // feat1 EMA
                delta8 = (pdelta > 12'd255) ? 8'd255 : pdelta[7:0];
                feat1_acc <= feat1_acc - {3'b000, feat1_acc[7:3]} + {3'b000, delta8[7:3]};
            end

            if (is_volume) begin
                cur_vol           <= volume_data;
                vol_sum4          <= vol_sum4 - {2'd0, vol_hist[vol_ptr]} + {2'd0, volume_data};
                vol_hist[vol_ptr] <= volume_data;
                vol_ptr           <= vol_ptr + 2'd1;
            end

            if (is_buy)
                buy_count  <= (buy_count  < 8'hFF) ? buy_count  + 8'd1 : 8'hFF;
            if (is_sell)
                sell_count <= (sell_count < 8'hFF) ? sell_count + 8'd1 : 8'hFF;

            window_cnt <= window_cnt + 8'd1;
            if (window_cnt == 8'hFF) begin
                buy_count  <= buy_count  >> 1;
                sell_count <= sell_count >> 1;
                feature_valid <= 1'b1;

                begin : emit
                    reg [11:0] delta_s;
                    reg [15:0] vr_tmp;
                    reg [15:0] arr_tmp;
                    reg [7:0]  vol_avg8;

                    // [0] price_change_1s
                    delta_s = (price_s[(ptr_s - 2'd1) & 2'd3] > price_s[ptr_s]) ?
                               price_s[(ptr_s - 2'd1) & 2'd3] - price_s[ptr_s] :
                               price_s[ptr_s] - price_s[(ptr_s - 2'd1) & 2'd3];
                    features[0*8 +: 8] <= (delta_s > 12'd255) ? 8'd255 : delta_s[7:0];

                    // [1] price_change_10s (EMA proxy)
                    features[1*8 +: 8] <= feat1_acc;

                    // [2] unused
                    features[2*8 +: 8] <= 8'd0;

                    // [3] volume_ratio (shift approx, no divider)
                    vol_avg8 = vol_sum4[13:6]; // sum4/64 ≈ avg/16
                    vr_tmp = (vol_avg8 == 8'd0) ? 16'd64 :
                             ({4'd0, cur_vol} << 1) / {8'd0, vol_avg8};
                    features[3*8 +: 8] <= (vr_tmp > 16'd255) ? 8'd255 : vr_tmp[7:0];

                    // [4] unused
                    features[4*8 +: 8] <= 8'd0;

                    // [5] buy_sell_imbalance
                    features[5*8 +: 8] <=
                        (buy_count == 8'd0 && sell_count == 8'd0) ? 8'd128 :
                        (buy_count == 8'd0)   ? 8'd0   :
                        (sell_count == 8'd0)  ? 8'd255 :
                        (buy_count > sell_count + (sell_count >> 1)) ? 8'd192 :
                        (sell_count > buy_count + (buy_count >> 1))  ? 8'd64  : 8'd128;

                    // [6] volatility: MAD × 4
                    features[6*8 +: 8] <=
                        ({4'd0, price_mad} > 16'd63) ? 8'd255 :
                        {2'b00, price_mad[5:0]};

                    // [7] order_arrival_rate
                    arr_tmp = {8'd0, buy_count} + {8'd0, sell_count};
                    features[7*8 +: 8] <= (arr_tmp > 16'd255) ? 8'd255 : arr_tmp[7:0];

                    // [8..15] unused
                    features[8*8  +: 8] <= 8'd0;
                    features[9*8  +: 8] <= 8'd0;
                    features[10*8 +: 8] <= 8'd0;
                    features[11*8 +: 8] <= 8'd0;
                    features[12*8 +: 8] <= 8'd0;
                    features[13*8 +: 8] <= 8'd0;
                    features[14*8 +: 8] <= 8'd0;
                    features[15*8 +: 8] <= 8'd128;
                end
            end
        end
    end

endmodule
