/*
 * NanoTrade ML Inference Engine  (v4 — Threshold Classifier, area-minimal)
 * =========================================================================
 * The full neural network (even 8→2→6) is too large for a 1×1 TT tile.
 * This version replaces it with a purely combinational threshold classifier:
 *
 *   - No multiplications, no pipeline registers (except output latch)
 *   - Uses 4 key features directly from the feature vector
 *   - Maps feature patterns to the same 6-class output as the MLP
 *   - Estimated area: ~200 cells vs ~3000+ for the MLP
 *
 * Feature inputs used:
 *   feat[0] = price_change_1s   (large → spike or crash)
 *   feat[1] = price_change_10s  (large → sustained move)
 *   feat[3] = volume_ratio      (high → volume surge)
 *   feat[5] = buy_sell_imbalance(extreme → imbalance)
 *   feat[6] = volatility        (high → volatile market)
 *   feat[7] = order_arrival_rate(high → quote stuffing)
 *
 * Classification logic (priority order):
 *   FLASH_CRASH (3)    : price_change_1s > 180 AND price_change_10s > 100
 *   QUOTE_STUFFING (5) : order_arrival_rate > 200 AND volume_ratio < 80
 *   VOLUME_SURGE (2)   : volume_ratio > 180
 *   PRICE_SPIKE (1)    : price_change_1s > 120
 *   ORDER_IMBALANCE(4) : imbalance < 40 OR imbalance > 215
 *   NORMAL (0)         : otherwise
 *
 * Confidence = scaled distance from threshold (0..255)
 * ml_valid pulses 1 cycle after feature_valid.
 */

`default_nettype none

module ml_inference_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [127:0] features,
    input  wire         feature_valid,
    output reg  [2:0]  ml_class,
    output reg  [7:0]  ml_confidence,
    output reg         ml_valid
);

    // Unpack the 6 features we use
    wire [7:0] f_price1  = features[ 0*8 +: 8];  // price_change_1s
    wire [7:0] f_price10 = features[ 1*8 +: 8];  // price_change_10s
    wire [7:0] f_volrat  = features[ 3*8 +: 8];  // volume_ratio
    wire [7:0] f_imbal   = features[ 5*8 +: 8];  // buy_sell_imbalance
    wire [7:0] f_volat   = features[ 6*8 +: 8];  // volatility
    wire [7:0] f_arriv   = features[ 7*8 +: 8];  // order_arrival_rate

    // Combinational classifier
    reg [2:0] c_class;
    reg [7:0] c_conf;

    always @(*) begin : classify
        if (f_price1 > 8'd180 && f_price10 > 8'd100) begin
            c_class = 3'd3; // FLASH_CRASH
            // confidence: how far above threshold (clipped)
            c_conf  = (f_price1 - 8'd180 > 8'd127) ? 8'd255 :
                      {1'b0, (f_price1 - 8'd180)} + {1'b0, (f_price10 > 8'd127 ? 8'd127 : f_price10 - 8'd100)};
        end else if (f_arriv > 8'd200 && f_volrat < 8'd80) begin
            c_class = 3'd5; // QUOTE_STUFFING
            c_conf  = f_arriv - 8'd200;
        end else if (f_volrat > 8'd180) begin
            c_class = 3'd2; // VOLUME_SURGE
            c_conf  = f_volrat - 8'd180;
        end else if (f_price1 > 8'd120) begin
            c_class = 3'd1; // PRICE_SPIKE
            c_conf  = f_price1 - 8'd120;
        end else if (f_imbal < 8'd40 || f_imbal > 8'd215) begin
            c_class = 3'd4; // ORDER_IMBALANCE
            c_conf  = (f_imbal < 8'd40) ? (8'd40 - f_imbal) : (f_imbal - 8'd215);
        end else begin
            c_class = 3'd0; // NORMAL
            c_conf  = 8'd0;
        end
    end

    // Single-cycle output latch
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid      <= 1'b0;
            ml_class      <= 3'd0;
            ml_confidence <= 8'd0;
        end else begin
            ml_valid <= feature_valid;
            if (feature_valid) begin
                ml_class      <= c_class;
                ml_confidence <= c_conf;
            end
        end
    end

endmodule
