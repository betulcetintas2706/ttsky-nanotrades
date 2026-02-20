/*
 * NanoTrade ML Inference Engine  (v3 — Area-Optimized for SKY130 1×1 tile)
 * ==========================================================================
 * Architecture: 8→2→6  (reduced from 16→4→6)
 *
 * Key changes vs v2:
 *   - Input features: 16 → 8  (uses features[0..7], most discriminative)
 *   - Hidden neurons: 4  → 2  (Layer-1 MACs: 64 → 16, 75% reduction)
 *   - Layer-2 MACs: 24 → 12
 *   - Weights: INT16 → INT8  (halves multiplier width)
 *   - Logits: 32-bit → 24-bit  (sufficient for INT8 weights)
 *
 * v3 fix: all loop variables in combinational always blocks changed from
 * `integer` to `reg` to prevent Yosys from inferring them as flip-flops
 * (which caused "conflicting driver" synthesis errors).
 *
 * Pipeline: 4 stages, feature_valid → ml_valid + 4 cycles.
 *
 * Classes: 0=NORMAL, 1=PRICE_SPIKE, 2=VOLUME_SURGE, 3=FLASH_CRASH,
 *          4=ORDER_IMBALANCE, 5=QUOTE_STUFFING
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

    // ---------------------------------------------------------------
    // Weight ROMs — INT8
    // ---------------------------------------------------------------

    // W1[in*2 + h]  8×2=16 entries
    function signed [7:0] rom_w1;
        input [3:0] addr;
        begin
            case (addr)
                4'd0:  rom_w1 = 8'shFA;
                4'd1:  rom_w1 = 8'sh0D;
                4'd2:  rom_w1 = 8'shF1;
                4'd3:  rom_w1 = 8'sh08;
                4'd4:  rom_w1 = 8'sh04;
                4'd5:  rom_w1 = 8'sh00;
                4'd6:  rom_w1 = 8'sh08;
                4'd7:  rom_w1 = 8'shEA;
                4'd8:  rom_w1 = 8'sh06;
                4'd9:  rom_w1 = 8'sh09;
                4'd10: rom_w1 = 8'shFD;
                4'd11: rom_w1 = 8'shFE;
                4'd12: rom_w1 = 8'sh03;
                4'd13: rom_w1 = 8'sh08;
                4'd14: rom_w1 = 8'shFF;
                4'd15: rom_w1 = 8'sh01;
                default: rom_w1 = 8'sh00;
            endcase
        end
    endfunction

    // b1[h]  2 entries
    function signed [7:0] rom_b1;
        input [0:0] addr;
        begin
            case (addr)
                1'd0: rom_b1 = 8'shEE;
                1'd1: rom_b1 = 8'sh1D;
                default: rom_b1 = 8'sh00;
            endcase
        end
    endfunction

    // W2[h*6 + o]  2×6=12 entries
    function signed [7:0] rom_w2;
        input [3:0] addr;
        begin
            case (addr)
                4'd0:  rom_w2 = 8'shF6;
                4'd1:  rom_w2 = 8'shF7;
                4'd2:  rom_w2 = 8'sh27;
                4'd3:  rom_w2 = 8'shED;
                4'd4:  rom_w2 = 8'shDF;
                4'd5:  rom_w2 = 8'sh06;
                4'd6:  rom_w2 = 8'shDA;
                4'd7:  rom_w2 = 8'sh11;
                4'd8:  rom_w2 = 8'shFB;
                4'd9:  rom_w2 = 8'shEA;
                4'd10: rom_w2 = 8'sh27;
                4'd11: rom_w2 = 8'shF1;
                default: rom_w2 = 8'sh00;
            endcase
        end
    endfunction

    // b2[o]  6 entries
    function signed [7:0] rom_b2;
        input [2:0] addr;
        begin
            case (addr)
                3'd0: rom_b2 = 8'shDC;
                3'd1: rom_b2 = 8'shE1;
                3'd2: rom_b2 = 8'shE2;
                3'd3: rom_b2 = 8'sh40;
                3'd4: rom_b2 = 8'shE6;
                3'd5: rom_b2 = 8'shDC;
                default: rom_b2 = 8'sh00;
            endcase
        end
    endfunction

    // ---------------------------------------------------------------
    // Feature unpacking — first 8 features only
    // ---------------------------------------------------------------
    wire [7:0] feat [0:7];
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : unpack
            assign feat[gi] = features[gi*8 +: 8];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Pipeline stage registers
    // ---------------------------------------------------------------
    reg [7:0] s0_feat [0:7];
    reg       s0_valid;

    reg [7:0] s1_hidden [0:1];
    reg       s1_valid;

    reg signed [23:0] s2_logit [0:5];
    reg               s2_valid;

    // ---------------------------------------------------------------
    // Stage 0: Latch inputs
    // ---------------------------------------------------------------
    // Use integer here (sequential block) — safe, won't cause Yosys issues
    integer k0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            for (k0 = 0; k0 < 8; k0 = k0 + 1)
                s0_feat[k0] <= 8'd0;
        end else begin
            s0_valid <= feature_valid;
            if (feature_valid) begin
                for (k0 = 0; k0 < 8; k0 = k0 + 1)
                    s0_feat[k0] <= feat[k0];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 1: Layer-1 MAC (combinational)
    // IMPORTANT: loop vars declared as reg (not integer) inside named
    // block to prevent Yosys inferring them as flip-flops.
    // ---------------------------------------------------------------
    reg signed [23:0] acc1_comb [0:1];
    reg [7:0]         s1_next   [0:1];

    always @(*) begin : s1_mac_comb
        reg [3:0] h1, i1;
        for (h1 = 4'd0; h1 < 4'd2; h1 = h1 + 4'd1) begin
            acc1_comb[h1] = 24'sd0;
            for (i1 = 4'd0; i1 < 4'd8; i1 = i1 + 4'd1)
                acc1_comb[h1] = acc1_comb[h1] +
                    ($signed({1'b0, s0_feat[i1]}) *
                     $signed(rom_w1(i1 * 4'd2 + h1)));
            acc1_comb[h1] = acc1_comb[h1] + $signed({rom_b1(h1[0:0]), 8'h00});
            if (acc1_comb[h1] <= 24'sd0)
                s1_next[h1] = 8'd0;
            else if (acc1_comb[h1][23:8] > 16'h00FF)
                s1_next[h1] = 8'd255;
            else
                s1_next[h1] = acc1_comb[h1][15:8];
        end
    end

    integer k1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            for (k1 = 0; k1 < 2; k1 = k1 + 1)
                s1_hidden[k1] <= 8'd0;
        end else begin
            s1_valid <= s0_valid;
            if (s0_valid) begin
                s1_hidden[0] <= s1_next[0];
                s1_hidden[1] <= s1_next[1];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: Layer-2 MAC (combinational)
    // ---------------------------------------------------------------
    reg signed [23:0] acc2_comb [0:5];

    always @(*) begin : s2_mac_comb
        reg [3:0] h2, o2;
        for (o2 = 4'd0; o2 < 4'd6; o2 = o2 + 4'd1) begin
            acc2_comb[o2] = 24'sd0;
            for (h2 = 4'd0; h2 < 4'd2; h2 = h2 + 4'd1)
                acc2_comb[o2] = acc2_comb[o2] +
                    ($signed({1'b0, s1_hidden[h2]}) *
                     $signed(rom_w2(h2 * 4'd6 + o2)));
            acc2_comb[o2] = acc2_comb[o2] + $signed({rom_b2(o2[2:0]), 8'h00});
        end
    end

    integer k2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            for (k2 = 0; k2 < 6; k2 = k2 + 1)
                s2_logit[k2] <= 24'sd0;
        end else begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_logit[0] <= acc2_comb[0];
                s2_logit[1] <= acc2_comb[1];
                s2_logit[2] <= acc2_comb[2];
                s2_logit[3] <= acc2_comb[3];
                s2_logit[4] <= acc2_comb[4];
                s2_logit[5] <= acc2_comb[5];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: Argmax (combinational)
    // ---------------------------------------------------------------
    reg [2:0] s3_class;
    reg [7:0] s3_confidence;

    always @(*) begin : s3_argmax_comb
        reg signed [23:0] mx_logit;
        reg signed [23:0] mn_logit;
        reg [2:0]         bc;
        reg signed [23:0] gap;
        reg [3:0]         j3;

        mx_logit = s2_logit[0];
        mn_logit = s2_logit[0];
        bc       = 3'd0;

        for (j3 = 4'd1; j3 < 4'd6; j3 = j3 + 4'd1) begin
            if (s2_logit[j3] > mx_logit) begin
                mx_logit = s2_logit[j3];
                bc       = j3[2:0];
            end
            if (s2_logit[j3] < mn_logit)
                mn_logit = s2_logit[j3];
        end

        s3_class = bc;
        gap = mx_logit - mn_logit;
        if (gap >= 24'sd65280)
            s3_confidence = 8'd255;
        else if (gap <= 24'sd0)
            s3_confidence = 8'd0;
        else
            s3_confidence = gap[15:8];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid      <= 1'b0;
            ml_class      <= 3'd0;
            ml_confidence <= 8'd0;
        end else begin
            ml_valid <= s2_valid;
            if (s2_valid) begin
                ml_class      <= s3_class;
                ml_confidence <= s3_confidence;
            end
        end
    end

endmodule
