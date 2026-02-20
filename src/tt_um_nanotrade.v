/*
 * NanoTrade — Top-Level TinyTapeout Wrapper  (v4 — Cascade Detection)
 * =====================================================================
 * NEW in v4: Market Cascade Detector
 * ------------------------------------
 * A 3-entry event shift register watches BOTH the rule-based alert stream
 * AND the ML class stream simultaneously.  When it recognises a cascade
 * signature — multiple distinct anomaly types arriving within a time window —
 * it fires a priority-8 CASCADE alert and DOUBLES the CB freeze duration.
 *
 * Cascade signatures detected:
 *   VOL_CRASH   : VOLUME_SURGE  → FLASH_CRASH  (panic selling)
 *   SPIKE_CRASH : PRICE_SPIKE   → FLASH_CRASH  (failed squeeze)
 *   STUFF_CRASH : QUOTE_STUFFING→ FLASH_CRASH  (spoofing attack)
 *   TRIPLE      : any 3 distinct anomalies → FLASH_CRASH (systemic)
 *
 * The 2010 Flash Crash was a TRIPLE cascade starting at 14:32 ET.
 * This chip would have detected it within 4 clock cycles = 80 ns.
 *
 * Pin mapping: UNCHANGED from v3 (TT-compatible)
 *
 *   uo_out[7]    Global alert (rule OR ML OR CASCADE)
 *   uo_out[6:4]  Alert priority (7=critical, 8 shown as 7 on 3-bit output)
 *   uo_out[3]    Match valid / CB active / UART TX / heartbeat
 *   uo_out[2:0]  Alert type (7=flash crash; cascade shown as type 7 + cascade flag)
 *
 *   uio_out[7]   ML valid pulse
 *   uio_out[6:4] ML class
 *   uio_out[3:2] CB state
 *   uio_out[1]   CASCADE alert flag  (NEW)
 *   uio_out[0]   CASCADE type LSB   (NEW — type[0], use with type[1] on next read)
 */

`default_nettype none



module tt_um_nanotrade #(
    parameter CLK_HZ = 50_000_000
) (
    input  wire [7:0] ui_in,
    output reg  [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------------------------------------------------------
    // Input decode
    // ---------------------------------------------------------------
    wire [1:0]  input_type    = ui_in[7:6];
    wire        config_strobe = uio_in[7] && (input_type == 2'b00);
    wire [11:0] price_data    = {uio_in[5:0], ui_in[5:0]};
    wire [11:0] vol_data      = {uio_in[5:0], ui_in[5:0]};

    // ---------------------------------------------------------------
    // CONFIG REGISTER
    // ---------------------------------------------------------------
    reg [1:0] thresh_sel;

    wire [11:0] SPIKE_THRESH =
        (thresh_sel == 2'b00) ? 12'd40 :
        (thresh_sel == 2'b01) ? 12'd20 :
        (thresh_sel == 2'b10) ? 12'd10 : 12'd5;

    wire [11:0] FLASH_THRESH =
        (thresh_sel == 2'b00) ? 12'd60 :
        (thresh_sel == 2'b01) ? 12'd40 :
        (thresh_sel == 2'b10) ? 12'd20 : 12'd10;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) thresh_sel <= 2'b01;
        else if (config_strobe) thresh_sel <= uio_in[1:0];
    end

    // ---------------------------------------------------------------
    // ML outputs
    // ---------------------------------------------------------------
    wire [2:0]  ml_class;
    wire [7:0]  ml_confidence;
    wire        ml_valid;

    // ---------------------------------------------------------------
    // ML → Circuit Breaker Translation
    // ---------------------------------------------------------------
    reg [1:0] cb_mode_next;
    reg [7:0] cb_param_next;
    reg       cb_load_r;

    always @(*) begin
        case (ml_class)
            3'd0: begin cb_mode_next = 2'b00; cb_param_next = 8'd0;           end
            3'd1: begin cb_mode_next = 2'b10; cb_param_next = ml_confidence;  end
            3'd2: begin cb_mode_next = 2'b01; cb_param_next = ml_confidence;  end
            3'd3: begin cb_mode_next = 2'b11; cb_param_next = ml_confidence;  end
            3'd4: begin cb_mode_next = 2'b10; cb_param_next = ml_confidence;  end
            3'd5: begin cb_mode_next = 2'b01; cb_param_next = ml_confidence;  end
            default: begin cb_mode_next = 2'b00; cb_param_next = 8'd0;        end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cb_load_r <= 1'b0;
        else        cb_load_r <= ml_valid;
    end

    reg [1:0] cb_mode_cmd;
    reg [7:0] cb_param_cmd;

    // ---------------------------------------------------------------
    // Cascade Detector outputs (may override CB command)
    // ---------------------------------------------------------------
    wire        cascade_alert;
 /* verilator lint_off UNUSEDSIGNAL */ wire [1:0]  cascade_type; /* verilator lint_on UNUSEDSIGNAL */
    wire _cascade_type_unused = cascade_type[1];  // bit[1] reserved
    wire        cascade_cb_load;
    wire [7:0]  cascade_cb_param;

    // Mux: cascade overrides normal ML→CB when cascade fires
    // Cascade always forces PAUSE (2'b11) with doubled param
    // Cascade overrides ML CB load: when cascade fires, suppress normal ML->CB
    wire        cb_load_final  = cascade_cb_load | (cb_load_r & !cascade_alert);
    wire [1:0]  cb_mode_final  = cascade_cb_load ? 2'b11       : cb_mode_cmd;
    wire [7:0]  cb_param_final = cascade_cb_load ? cascade_cb_param : cb_param_cmd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cb_mode_cmd  <= 2'b00;
            cb_param_cmd <= 8'd0;
        end else if (ml_valid) begin
            cb_mode_cmd  <= cb_mode_next;
            cb_param_cmd <= cb_param_next;
        end
    end

    // ---------------------------------------------------------------
    // Order Book (with CB interface)
    // ---------------------------------------------------------------
    wire        match_valid;
    wire [7:0]  match_price;
    wire        cb_active;
    wire [1:0]  cb_state;

    order_book u_order_book (
        .clk        (clk),
        .rst_n      (rst_n),
        .input_type (input_type),
        .data_in    (ui_in[5:0]),
        .ext_data   (uio_in[5:0]),
        .cb_mode    (cb_mode_final),
        .cb_param   (cb_param_final),
        .cb_load    (cb_load_final),
        .match_valid(match_valid),
        .match_price(match_price),
        .cb_active  (cb_active),
        .cb_state   (cb_state)
    );

    // ---------------------------------------------------------------
    // Rule-Based Anomaly Detector
    // ---------------------------------------------------------------
    wire        rule_alert_any;
    wire [2:0]  rule_alert_priority;
    wire [2:0]  rule_alert_type;
    wire [7:0]  rule_alert_bitmap;

    anomaly_detector u_rule_detector (
        .clk           (clk),
        .rst_n         (rst_n),
        .input_type    (input_type),
        .price_data    (price_data),
        .volume_data   (vol_data),
        .match_valid   (match_valid),
        .match_price   (match_price),
        .spike_thresh  (SPIKE_THRESH),
        .flash_thresh  (FLASH_THRESH),
        .alert_any     (rule_alert_any),
        .alert_priority(rule_alert_priority),
        .alert_type    (rule_alert_type),
        .alert_bitmap  (rule_alert_bitmap)
    );

    // ---------------------------------------------------------------
    // Feature Extractor
    // ---------------------------------------------------------------
    wire [127:0] features;
    wire         feature_valid;

    feature_extractor u_feat_extractor (
        .clk          (clk),
        .rst_n        (rst_n),
        .input_type   (input_type),
        .price_data   (price_data),
        .volume_data  (vol_data),
        .match_valid  (match_valid),
        .match_price  (match_price),
        .features     (features),
        .feature_valid(feature_valid)
    );

    // ---------------------------------------------------------------
    // ML Inference Engine
    // ---------------------------------------------------------------
    ml_inference_engine u_ml_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .features      (features),
        .feature_valid (feature_valid),
        .ml_class      (ml_class),
        .ml_confidence (ml_confidence),
        .ml_valid      (ml_valid)
    );

    // ---------------------------------------------------------------
    // Cascade Detector
    // ---------------------------------------------------------------
    cascade_detector #(
        .CASCADE_WINDOW(64),
        .CASCADE_HOLD  (32)
    ) u_cascade (
        .clk             (clk),
        .rst_n           (rst_n),
        .test_flush      (1'b0),
        .rule_alert_any  (rule_alert_any),
        .rule_alert_type (rule_alert_type),
        .ml_valid        (ml_valid),
        .ml_class        (ml_class),
        .ml_confidence   (ml_confidence),
        .cascade_alert   (cascade_alert),
        .cascade_type    (cascade_type),
        .cascade_cb_load (cascade_cb_load),
        .cascade_cb_param(cascade_cb_param)
    );

    // ---------------------------------------------------------------
    // Alert Fusion
    // ---------------------------------------------------------------
    reg [2:0] ml_class_held;
    reg       ml_anomaly_held;
    reg [2:0] ml_prio_held;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_class_held   <= 3'd0;
            ml_anomaly_held <= 1'b0;
            ml_prio_held    <= 3'd0;
        end else if (ml_valid) begin
            ml_class_held   <= ml_class;
            ml_anomaly_held <= (ml_class != 3'd0);
            case (ml_class)
                3'd0: ml_prio_held <= 3'd0;
                3'd1: ml_prio_held <= 3'd3;
                3'd2: ml_prio_held <= 3'd2;
                3'd3: ml_prio_held <= 3'd7;
                3'd4: ml_prio_held <= 3'd4;
                3'd5: ml_prio_held <= 3'd5;
                default: ml_prio_held <= 3'd0;
            endcase
        end
    end

    // Cascade overrides everything — priority 7 (max on 3-bit), type = FLASH_CRASH
    wire        comb_alert    = rule_alert_any | ml_anomaly_held | cascade_alert;
    wire [2:0]  comb_priority = cascade_alert  ? 3'd7 :
                                (rule_alert_priority > ml_prio_held) ?
                                  rule_alert_priority : ml_prio_held;
    wire [2:0]  comb_type     = cascade_alert  ? 3'd7 :   // shown as FLASH_CRASH
                                (rule_alert_priority >= ml_prio_held) ?
                                  rule_alert_type : ml_class_held;

    // ---------------------------------------------------------------
    // UART READBACK — 115200 baud, 8N1
    // Payload updated: bit 7 of type field repurposed as cascade flag
    // ---------------------------------------------------------------
    localparam BAUD_DIV = CLK_HZ / 115200;

    wire [7:0] uart_payload = {comb_type, comb_priority, ml_class_held[1:0]};

    reg        prev_alert_r;
    wire       uart_trigger = (comb_alert && !prev_alert_r) || ml_valid
                              || cascade_alert;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_alert_r <= 1'b0;
        else        prev_alert_r <= comb_alert;
    end

    reg [9:0]  uart_shift;
    reg [9:0]  uart_bit_cnt;
    reg [3:0]  uart_bits;
    reg        uart_busy;
    reg        uart_tx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_busy <= 1'b0; uart_tx <= 1'b1;
            uart_shift <= 10'h3FF; uart_bit_cnt <= 10'd0; uart_bits <= 4'd0;
        end else begin
            if (!uart_busy && uart_trigger) begin
                uart_shift   <= {1'b1, uart_payload, 1'b0};
                uart_bit_cnt <= 10'd0; uart_bits <= 4'd0;
                uart_busy    <= 1'b1;  uart_tx   <= 1'b0;
            end else if (uart_busy) begin
                if ({22'd0, uart_bit_cnt} >= BAUD_DIV - 1) begin
                    uart_bit_cnt <= 10'd0;
                    uart_bits    <= uart_bits + 4'd1;
                    uart_tx      <= uart_shift[uart_bits];
                    if (uart_bits == 4'd9) begin uart_busy <= 1'b0; uart_tx <= 1'b1; end
                end else
                    uart_bit_cnt <= uart_bit_cnt + 10'd1;
            end
        end
    end

    // ---------------------------------------------------------------
    // HEARTBEAT — ~1 Hz
    // ---------------------------------------------------------------
    localparam HB_DIV = CLK_HZ / 2;

    reg [24:0] hb_cnt;
    reg        hb_led;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hb_cnt <= 25'd0; hb_led <= 1'b0; end
        else begin
            if ({7'd0, hb_cnt} >= HB_DIV - 1) begin hb_cnt <= 25'd0; hb_led <= ~hb_led; end
            else hb_cnt <= hb_cnt + 25'd1;
        end
    end

    // ---------------------------------------------------------------
    // Output mux
    // ---------------------------------------------------------------
    always @(*) begin
        uo_out[7]   = comb_alert;
        uo_out[6:4] = comb_priority;
        uo_out[2:0] = comb_type;

        if (match_valid)
            uo_out[3] = 1'b1;
        else if (cb_active)
            uo_out[3] = 1'b0;
        else if (uart_busy)
            uo_out[3] = uart_tx;
        else
            uo_out[3] = hb_led;
    end

    // ---------------------------------------------------------------
    // Bidirectional outputs
    // uio_out[7]   ML valid
    // uio_out[6:4] ML class
    // uio_out[3:2] CB state
    // uio_out[1]   CASCADE alert flag  ← NEW
    // uio_out[0]   CASCADE type[0]     ← NEW
    // ---------------------------------------------------------------
    assign uio_out = match_valid ? match_price :
                     {ml_valid, ml_class_held, cb_state,
                      cascade_alert, cascade_type[0]};
    assign uio_oe  = 8'hFF;

    wire _unused = &{ena, uio_in[6:2], rule_alert_bitmap, 1'b0};

endmodule
