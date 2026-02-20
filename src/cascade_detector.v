/*
 * cascade_detector.v  — NanoTrade v4
 * ---------------------------------
 * Detects multi-event cascades within CASCADE_WINDOW cycles.
 * Exposes internal shift register as: hist[0], hist[1], hist[2]
 * so tb_cascade can probe it via dut.u_cascade.hist[...].
 *
 * Cascade patterns:
 *   VOL_CRASH   : VOLUME_SURGE (2) -> FLASH_CRASH (3)
 *   SPIKE_CRASH : PRICE_SPIKE  (1) -> FLASH_CRASH (3)
 *   STUFF_CRASH : QUOTE_STUFF  (5) -> FLASH_CRASH (3)
 *   TRIPLE      : any 3 distinct anomalies ending in FLASH_CRASH (3)
 *
 * When a cascade fires:
 *   - cascade_alert is held for CASCADE_HOLD cycles
 *   - cascade_cb_load pulses for 1 cycle
 *   - cascade_cb_param = 2 * ml_confidence (saturating at 255)
 */

`default_nettype none



module cascade_detector #(
    parameter integer CASCADE_WINDOW = 64,
    parameter integer CASCADE_HOLD   = 32
) (
    input  wire       clk,
    input  wire       rst_n,

    // optional test hook (you can ignore; tb may drive it)
    input  wire       test_flush,

    // rule stream
    input  wire       rule_alert_any,
    input  wire [2:0] rule_alert_type,

    // ML stream
    input  wire       ml_valid,
    input  wire [2:0] ml_class,
    input  wire [7:0] ml_confidence,

    // outputs
    output reg        cascade_alert,
    output reg  [1:0] cascade_type,
    output reg        cascade_cb_load,
    output reg  [7:0] cascade_cb_param
);

    // ------------------------------------------------------------
    // Public internal history (tb probes dut.u_cascade.hist[i])
    // ------------------------------------------------------------
    reg [2:0] hist [0:2];

    // last-event age counter (to expire precursors)
    reg [$clog2(CASCADE_WINDOW+2)-1:0] age_cnt;

    // hold counter for visible cascade_alert
    reg [$clog2(CASCADE_HOLD+2)-1:0] hold_cnt;

    // ------------------------------------------------------------
    // Event selection (one event per cycle max)
    // Priority: ML anomaly > rule anomaly (so tests are stable)
    // ------------------------------------------------------------
    wire ml_evt   = ml_valid && (ml_class != 3'd0);
    wire rule_evt = rule_alert_any;

    wire event_any = ml_evt || rule_evt;

    wire [2:0] event_code = ml_evt   ? ml_class :
                            rule_evt ? rule_alert_type :
                            3'd0;

    // ------------------------------------------------------------
    // Cascade type encoding
    // ------------------------------------------------------------
    localparam [1:0] CT_VOL_CRASH   = 2'd0;
    localparam [1:0] CT_SPIKE_CRASH = 2'd1;
    localparam [1:0] CT_STUFF_CRASH = 2'd2;
    localparam [1:0] CT_TRIPLE      = 2'd3;

    // saturating multiply by 2
    wire [8:0] conf_x2_wide = {1'b0, ml_confidence} << 1;
    wire [7:0] conf_x2_sat  = conf_x2_wide[8] ? 8'hFF : conf_x2_wide[7:0];

    // ------------------------------------------------------------
    // Combinational cascade detection based on hist after shift
    // (We compute using "next" values)
    // ------------------------------------------------------------
    wire [2:0] h1_next = event_any ? hist[0]    : hist[1];
    wire [2:0] h2_next = event_any ? hist[1]    : hist[2];

    // Only detect cascades when the NEW event is FLASH_CRASH (3)
    wire new_is_flash = event_any && (event_code == 3'd3);

    wire is_vol_crash   = new_is_flash && (h1_next == 3'd2);
    wire is_spike_crash = new_is_flash && (h1_next == 3'd1);
    wire is_stuff_crash = new_is_flash && (h1_next == 3'd5);

    // TRIPLE: previous two are non-zero, distinct, and not FLASH
    wire is_triple =
        new_is_flash &&
        (h1_next != 3'd0) && (h2_next != 3'd0) &&
        (h1_next != h2_next) &&
        (h1_next != 3'd3) && (h2_next != 3'd3);

    wire cascade_fire = is_vol_crash || is_spike_crash || is_stuff_crash || is_triple;

    wire [1:0] cascade_type_next =
        is_triple      ? CT_TRIPLE :
        is_stuff_crash ? CT_STUFF_CRASH :
        is_spike_crash ? CT_SPIKE_CRASH :
        /*vol*/          CT_VOL_CRASH;

    // ------------------------------------------------------------
    // Sequential logic
    // ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist[0] <= 3'd0;
            hist[1] <= 3'd0;
            hist[2] <= 3'd0;

            age_cnt <= 'd0;

            cascade_alert    <= 1'b0;
            cascade_type     <= 2'd0;
            cascade_cb_load  <= 1'b0;
            cascade_cb_param <= 8'd0;
            hold_cnt         <= 'd0;
        end else begin
            // default: pulses low
            cascade_cb_load <= 1'b0;

            // optional flush for tests/debug
            if (test_flush) begin
                hist[0] <= 3'd0;
                hist[1] <= 3'd0;
                hist[2] <= 3'd0;
                age_cnt <= 'd0;
            end else begin
                // age counter / expiry
                if (event_any) begin
                    age_cnt <= 'd0;
                end else if (age_cnt < CASCADE_WINDOW[$bits(age_cnt)-1:0]) begin
                    age_cnt <= age_cnt + 'd1;
                end

                // If window expired, wipe precursors so next event is "isolated"
                if (!event_any && (age_cnt == CASCADE_WINDOW[$bits(age_cnt)-1:0])) begin
                    hist[0] <= 3'd0;
                    hist[1] <= 3'd0;
                    hist[2] <= 3'd0;
                end else if (event_any) begin
                    // shift history on event
                    hist[2] <= hist[1];
                    hist[1] <= hist[0];
                    hist[0] <= event_code;
                end
            end

            // cascade hold handling
            if (cascade_fire) begin
                cascade_alert   <= 1'b1;
                cascade_type    <= cascade_type_next;

                // pulse to override CB exactly 1 cycle
                cascade_cb_load  <= 1'b1;
                cascade_cb_param <= conf_x2_sat;

                hold_cnt <= CASCADE_HOLD[$bits(hold_cnt)-1:0];
            end else if (cascade_alert) begin
                if (hold_cnt != 'd0) begin
                    hold_cnt <= hold_cnt - 'd1;
                end else begin
                    cascade_alert <= 1'b0;
                end
            end
        end
    end

endmodule
