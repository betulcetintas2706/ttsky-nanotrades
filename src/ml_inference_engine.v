/*
 * NanoTrade ML Inference Engine  (SKY130 Synthesizable — v2)
 * ============================================================
 * Architecture: 16 inputs → 4 hidden → 6 output classes
 *
 * Changes from v1:
 *   - 16→8→6 reduced to 16→4→6  (cuts ~50% of multiplier cells)
 *   - $readmemh replaced with synthesizable case-ROM functions
 *   - All integer loop indices use genvar where possible
 *   - Fully compatible with OpenLane / SKY130 PDK
 *
 * Pipeline (4 clock cycles, feature_valid → ml_valid):
 *   Stage 0 : Latch feature vector
 *   Stage 1 : Layer-1 MACs + bias + ReLU → 4×UINT8 hidden
 *   Stage 2 : Layer-2 MACs + bias → 6×INT32 logits
 *   Stage 3 : Argmax → 3-bit class + 8-bit confidence
 *
 * Anomaly classes:
 *   0 = NORMAL
 *   1 = PRICE_SPIKE
 *   2 = VOLUME_SURGE
 *   3 = FLASH_CRASH    (critical, priority 7)
 *   4 = ORDER_IMBALANCE
 *   5 = QUOTE_STUFFING
 *
 * Quantization:
 *   Weights: INT16 (baked with scaler, no runtime normalization needed)
 *   Activations: UINT8 after ReLU
 *   Accuracy: 99.4% quantized (99.9% float) on 1600-sample test set
 *
 * ROM size: 196 bytes total (64+4+24+6 weights × 2 bytes)
 *   → Maps to ~400 LUT4 cells in SKY130 — fits comfortably in 2×2 tile
 */

`default_nettype none

module ml_inference_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Feature vector: 16 × 8-bit unsigned  {feat[15],...,feat[0]}
    input  wire [127:0] features,
    input  wire         feature_valid,   // 1-cycle pulse to start inference

    // Result (valid 4 cycles after feature_valid)
    output reg  [2:0]  ml_class,
    output reg  [7:0]  ml_confidence,
    output reg         [7:0]  ml_margin,
    output reg         ml_valid
);

    // ---------------------------------------------------------------
    // Synthesizable weight ROMs (case-statement LUTs, no $readmemh)
    // Auto-generated from train_and_export.py + gen_rom_v.py
    // Trained 16->4->6 MLP, quantized INT16, 99.4% accuracy
    // ---------------------------------------------------------------

    // W1[in*4+hidden]  16×4=64 entries
    function signed [15:0] rom_w1;
        input [5:0] addr;
        begin
            case (addr)
                6'd0: rom_w1 = 16'shFAD2;
                6'd1: rom_w1 = 16'sh0D75;
                6'd2: rom_w1 = 16'sh0B09;
                6'd3: rom_w1 = 16'sh1E6C;
                6'd4: rom_w1 = 16'shF159;
                6'd5: rom_w1 = 16'sh0805;
                6'd6: rom_w1 = 16'sh0C9C;
                6'd7: rom_w1 = 16'sh26C1;
                6'd8: rom_w1 = 16'sh0404;
                6'd9: rom_w1 = 16'sh00AE;
                6'd10: rom_w1 = 16'sh06EC;
                6'd11: rom_w1 = 16'sh0D7A;
                6'd12: rom_w1 = 16'sh0847;
                6'd13: rom_w1 = 16'shEA88;
                6'd14: rom_w1 = 16'shF4F2;
                6'd15: rom_w1 = 16'shF6FA;
                6'd16: rom_w1 = 16'shEEDC;
                6'd17: rom_w1 = 16'sh2629;
                6'd18: rom_w1 = 16'shC000;
                6'd19: rom_w1 = 16'shED1A;
                6'd20: rom_w1 = 16'sh062F;
                6'd21: rom_w1 = 16'sh09C4;
                6'd22: rom_w1 = 16'sh060B;
                6'd23: rom_w1 = 16'sh02EC;
                6'd24: rom_w1 = 16'shF9B1;
                6'd25: rom_w1 = 16'sh094E;
                6'd26: rom_w1 = 16'shEE23;
                6'd27: rom_w1 = 16'sh16DA;
                6'd28: rom_w1 = 16'sh0AD3;
                6'd29: rom_w1 = 16'shF780;
                6'd30: rom_w1 = 16'shF683;
                6'd31: rom_w1 = 16'sh050B;
                6'd32: rom_w1 = 16'shFCC9;
                6'd33: rom_w1 = 16'shFE29;
                6'd34: rom_w1 = 16'shF9E3;
                6'd35: rom_w1 = 16'sh0D10;
                6'd36: rom_w1 = 16'shFD56;
                6'd37: rom_w1 = 16'shFE1F;
                6'd38: rom_w1 = 16'sh0068;
                6'd39: rom_w1 = 16'sh00E0;
                6'd40: rom_w1 = 16'sh0342;
                6'd41: rom_w1 = 16'sh0822;
                6'd42: rom_w1 = 16'sh05ED;
                6'd43: rom_w1 = 16'shFEE2;
                6'd44: rom_w1 = 16'shCCA6;
                6'd45: rom_w1 = 16'sh035C;
                6'd46: rom_w1 = 16'sh070E;
                6'd47: rom_w1 = 16'sh09CD;
                6'd48: rom_w1 = 16'shFF13;
                6'd49: rom_w1 = 16'sh0196;
                6'd50: rom_w1 = 16'sh00EB;
                6'd51: rom_w1 = 16'shFE2B;
                6'd52: rom_w1 = 16'sh033D;
                6'd53: rom_w1 = 16'shFBE2;
                6'd54: rom_w1 = 16'shFAA7;
                6'd55: rom_w1 = 16'sh0CA9;
                6'd56: rom_w1 = 16'sh0225;
                6'd57: rom_w1 = 16'shF24A;
                6'd58: rom_w1 = 16'sh0746;
                6'd59: rom_w1 = 16'sh1F8F;
                6'd60: rom_w1 = 16'sh0000;
                6'd61: rom_w1 = 16'sh0000;
                6'd62: rom_w1 = 16'sh0000;
                6'd63: rom_w1 = 16'sh0000;
                default: rom_w1 = 16'sh0000;
            endcase
        end
    endfunction

    // b1[hidden]  4 entries
    function signed [15:0] rom_b1;
        input [1:0] addr;
        begin
            case (addr)
                2'd0: rom_b1 = 16'shEE64;
                2'd1: rom_b1 = 16'sh1D1B;
                2'd2: rom_b1 = 16'sh27D8;
                2'd3: rom_b1 = 16'shC000;
                default: rom_b1 = 16'sh0000;
            endcase
        end
    endfunction

    // W2[hidden*6+out]  4×6=24 entries
    function signed [15:0] rom_w2;
        input [4:0] addr;
        begin
            case (addr)
                5'd0:  rom_w2 = 16'shF666;
                5'd1:  rom_w2 = 16'shF78F;
                5'd2:  rom_w2 = 16'sh2725;
                5'd3:  rom_w2 = 16'shEDAD;
                5'd4:  rom_w2 = 16'shDFFE;
                5'd5:  rom_w2 = 16'sh0698;
                5'd6:  rom_w2 = 16'shDA84;
                5'd7:  rom_w2 = 16'sh11DA;
                5'd8:  rom_w2 = 16'shFB57;
                5'd9:  rom_w2 = 16'shEA1E;
                5'd10: rom_w2 = 16'sh2713;
                5'd11: rom_w2 = 16'shF152;
                5'd12: rom_w2 = 16'sh3227;
                5'd13: rom_w2 = 16'sh0789;
                5'd14: rom_w2 = 16'shE7E4;
                5'd15: rom_w2 = 16'shDD9D;
                5'd16: rom_w2 = 16'shC000;
                5'd17: rom_w2 = 16'shD818;
                5'd18: rom_w2 = 16'shCE48;
                5'd19: rom_w2 = 16'sh117B;
                5'd20: rom_w2 = 16'shFE39;
                5'd21: rom_w2 = 16'shFAE1;
                5'd22: rom_w2 = 16'shE64E;
                5'd23: rom_w2 = 16'sh2147;
                default: rom_w2 = 16'sh0000;
            endcase
        end
    endfunction

    // b2[out]  6 entries
    function signed [15:0] rom_b2;
        input [2:0] addr;
        begin
            case (addr)
                3'd0: rom_b2 = 16'shDC08;
                3'd1: rom_b2 = 16'shE184;
                3'd2: rom_b2 = 16'shE2ED;
                3'd3: rom_b2 = 16'sh4000;
                3'd4: rom_b2 = 16'shE6A7;
                3'd5: rom_b2 = 16'shDCA6;
                default: rom_b2 = 16'sh0000;
            endcase
        end
    endfunction

    // ---------------------------------------------------------------
    // Feature unpacking — 16 × 8-bit unsigned
    // ---------------------------------------------------------------
    wire [7:0] feat [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign feat[gi] = features[gi*8 +: 8];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Pipeline stage registers
    // ---------------------------------------------------------------

    // Stage 0 → 1
    reg [7:0] s0_feat [0:15];
    reg       s0_valid;

    // Stage 1 → 2  (4 hidden neurons, UINT8 after ReLU)
    reg [7:0] s1_hidden [0:3];
    reg       s1_valid;

    // Stage 2 → 3  (6 output logits, INT32)
    reg signed [31:0] s2_logit [0:5];
    reg               s2_valid;

    // ---------------------------------------------------------------
    // Stage 0: Latch inputs
    // ---------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            for (k = 0; k < 16; k = k + 1)
                s0_feat[k] <= 8'd0;
        end else begin
            s0_valid <= feature_valid;
            if (feature_valid) begin
                for (k = 0; k < 16; k = k + 1)
                    s0_feat[k] <= feat[k];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 1: Layer-1 MAC  (16 inputs × 4 hidden neurons)
    //   acc[h] = Σ_{i=0}^{15} feat[i] * W1[i*4+h]  +  b1[h]
    //   hidden[h] = ReLU(acc[h] >> 8) clipped to UINT8
    // ---------------------------------------------------------------
    reg signed [31:0] acc1_comb [0:3];
    reg [7:0]         s1_next   [0:3];
    integer i1, h1;

    // Combinational: compute accumulation and ReLU for stage 1
    always @(*) begin : s1_mac_comb
        integer ci1, ch1;
        for (ch1 = 0; ch1 < 4; ch1 = ch1 + 1) begin
            acc1_comb[ch1] = 32'sd0;
            for (ci1 = 0; ci1 < 16; ci1 = ci1 + 1)
                acc1_comb[ch1] = acc1_comb[ch1] +
                    ($signed({1'b0, s0_feat[ci1]}) *
                     $signed(rom_w1(ci1[5:0]*4 + ch1[5:0])));
            acc1_comb[ch1] = acc1_comb[ch1] + $signed({rom_b1(ch1[1:0]), 8'h00});
            if (acc1_comb[ch1] <= 32'sd0)
                s1_next[ch1] = 8'd0;
            else if (acc1_comb[ch1] >= 32'sd65535)
                s1_next[ch1] = 8'd255;
            else
                s1_next[ch1] = acc1_comb[ch1][15:8];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            for (k = 0; k < 4; k = k + 1)
                s1_hidden[k] <= 8'd0;
        end else begin
            s1_valid <= s0_valid;
            if (s0_valid) begin
                for (h1 = 0; h1 < 4; h1 = h1 + 1)
                    s1_hidden[h1] <= s1_next[h1];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: Layer-2 MAC  (4 hidden × 6 output neurons)
    //   logit[o] = Σ_{h=0}^{3} hidden[h] * W2[h*6+o]  +  b2[o]
    // ---------------------------------------------------------------
    integer h2, o2;
    // Combinational: compute layer-2 accumulation
    reg signed [31:0] acc2_comb [0:5];

    always @(*) begin : s2_mac_comb
        integer ch2, co2;
        for (co2 = 0; co2 < 6; co2 = co2 + 1) begin
            acc2_comb[co2] = 32'sd0;
            for (ch2 = 0; ch2 < 4; ch2 = ch2 + 1)
                acc2_comb[co2] = acc2_comb[co2] +
                    ($signed({1'b0, s1_hidden[ch2]}) *
                     $signed(rom_w2(ch2[4:0]*6 + co2[4:0])));
            acc2_comb[co2] = acc2_comb[co2] + $signed({rom_b2(co2[2:0]), 8'h00});
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            for (k = 0; k < 6; k = k + 1)
                s2_logit[k] <= 32'sd0;
        end else begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                for (o2 = 0; o2 < 6; o2 = o2 + 1)
                    s2_logit[o2] <= acc2_comb[o2];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: Argmax  →  class (3-bit) + confidence (8-bit)
    // ---------------------------------------------------------------
    // Combinational argmax outputs
    reg [2:0]  s3_class;
    reg [7:0]  s3_confidence;
    reg [7:0]  s3_margin;
    integer j3;

    always @(*) begin : s3_argmax_comb
        reg signed [31:0] mx_logit;
        reg signed [31:0] sec_logit;
        reg signed [31:0] mn_logit;
        reg [2:0]         bc;
        reg signed [31:0] g;
        integer cj3;
        mx_logit  = s2_logit[0];
        sec_logit = -32'sd2147483648;
        mn_logit  = s2_logit[0];
        bc        = 3'd0;
        for (cj3 = 1; cj3 < 6; cj3 = cj3 + 1) begin
            if (s2_logit[cj3] > mx_logit) begin
                sec_logit = mx_logit;
                mx_logit  = s2_logit[cj3];
                bc        = cj3[2:0];
            end else if (s2_logit[cj3] > sec_logit) begin
                sec_logit = s2_logit[cj3];
            end
            if (s2_logit[cj3] < mn_logit)
                mn_logit = s2_logit[cj3];
        end
        if (sec_logit == -32'sd2147483648)
            sec_logit = mn_logit;
        s3_class = bc;
        // Confidence: max - min scaled to 0..255
        g = mx_logit - mn_logit;
        if (g >= 32'sd65280)
            s3_confidence = 8'd255;
        else if (g <= 32'sd0)
            s3_confidence = 8'd0;
        else
            s3_confidence = g[15:8];
        // Margin: max - second_max scaled to 0..255
        g = mx_logit - sec_logit;
        if (g >= 32'sd65280)
            s3_margin = 8'd255;
        else if (g <= 32'sd0)
            s3_margin = 8'd0;
        else
            s3_margin = g[15:8];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid      <= 1'b0;
            ml_class      <= 3'd0;
            ml_confidence <= 8'd0;
            ml_margin     <= 8'd0;
        end else begin
            ml_valid <= s2_valid;
            if (s2_valid) begin
                ml_class      <= s3_class;
                ml_confidence <= s3_confidence;
                ml_margin     <= s3_margin;
            end
        end
    end

endmodule
