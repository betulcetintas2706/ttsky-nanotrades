/*
 * NanoTrade Anomaly Detector
 *
 * 8 parallel detectors running every clock cycle:
 *   [0] Price Spike      - sudden price jump > threshold
 *   [1] Volume Surge     - volume > 2x rolling average
 *   [2] Trade Velocity   - too many matches per window
 *   [3] Volatility       - price MAD exceeds threshold
 *   [4] Volume Dry       - volume < 25% of average (liquidity crisis)
 *   [5] Spread Widening  - bid-ask spread too wide
 *   [6] Order Imbalance  - one-sided order pressure
 *   [7] Flash Crash      - price drop > 20% of baseline (critical)
 *
 * All detectors are COMBINATIONAL - they evaluate in parallel each cycle.
 * Priority encoder selects most critical active alert.
 *
 * Inputs:
 *   input_type  - 00=price, 01=volume, 10=buy, 11=sell
 *   price_data  - 12-bit price (from ui_in + uio_in)
 *   volume_data - 12-bit volume
 *   match_valid - order was matched this cycle (from order_book)
 *   match_price - matched price
 *
 * Outputs:
 *   alert_any      - any alert active
 *   alert_priority - 3-bit priority (7=critical flash crash)
 *   alert_type     - which alert is highest priority
 *   alert_bitmap   - all 8 alert flags
 */

`default_nettype none

module anomaly_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  input_type,
    input  wire [11:0] price_data,
    input  wire [11:0] volume_data,
    input  wire        match_valid,
    input  wire [7:0]  match_price,
    // Live threshold inputs from config register (set via UI at demo time)
    input  wire [11:0] spike_thresh,   // default 12'd20
    input  wire [11:0] flash_thresh,   // default 12'd40
    output wire        alert_any,
    output wire [2:0]  alert_priority,
    output wire [2:0]  alert_type,
    output wire [7:0]  alert_bitmap
);

    // ---------------------------------------------------------------
    // Registered history for rolling calculations
    // ---------------------------------------------------------------

    // Price history: 8-entry ring buffer of 12-bit prices
    reg [11:0] price_hist [0:7];
    reg [2:0]  price_ptr;

    // Volume history: 8-entry ring buffer
    reg [11:0] vol_hist [0:7];
    reg [2:0]  vol_ptr;

    // Baseline price (average of last 8, updated slowly)
    reg [14:0] price_sum;   // 12-bit * 8 needs 15 bits
    reg [11:0] price_avg;

    // Baseline volume
    reg [14:0] vol_sum;
    reg [11:0] vol_avg;

    // Trade velocity counter
    reg [5:0]  match_counter;  // matches in current window
    reg [7:0]  window_timer;   // window period counter
    reg [5:0]  match_rate;     // captured at window end

    // Bid/ask depth counters (from order book pressure)
    reg [3:0]  buy_order_count;
    reg [3:0]  sell_order_count;

    // Current values
    reg [11:0] current_price;
    reg [11:0] prev_price;
    reg [11:0] current_volume;

    // Mean Absolute Deviation for volatility
    reg [11:0] price_mad;

    wire is_price  = (input_type == 2'b00);
    wire is_volume = (input_type == 2'b01);
    wire is_buy    = (input_type == 2'b10);
    wire is_sell   = (input_type == 2'b11);

    integer i;

    // ---------------------------------------------------------------
    // Sequential: update history registers
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            price_ptr        <= 3'd0;
            vol_ptr          <= 3'd0;
            price_sum        <= 15'd0;
            vol_sum          <= 15'd0;
            price_avg        <= 12'd100;  // sane default
            vol_avg          <= 12'd100;
            match_counter    <= 6'd0;
            window_timer     <= 8'd0;
            match_rate       <= 6'd0;
            buy_order_count  <= 4'd0;
            sell_order_count <= 4'd0;
            current_price    <= 12'd100;
            prev_price       <= 12'd100;
            current_volume   <= 12'd0;
            price_mad        <= 12'd5;
            for (i = 0; i < 8; i = i + 1) begin
                price_hist[i] <= 12'd100;
                vol_hist[i]   <= 12'd100;
            end
        end else begin

            // Update price history
            if (is_price) begin
                prev_price               <= current_price;
                current_price            <= price_data;
                price_sum                <= price_sum - price_hist[price_ptr] + price_data;
                price_hist[price_ptr]    <= price_data;
                price_ptr                <= price_ptr + 3'd1;
                price_avg                <= price_sum[14:3]; // divide by 8

                // Update MAD (simplified: |price - avg| rolling average)
                if (price_data > price_avg)
                    price_mad <= (price_mad * 7 + (price_data - price_avg)) >> 3;
                else
                    price_mad <= (price_mad * 7 + (price_avg - price_data)) >> 3;
            end

            // Update volume history
            if (is_volume) begin
                current_volume        <= volume_data;
                vol_sum               <= vol_sum - vol_hist[vol_ptr] + volume_data;
                vol_hist[vol_ptr]     <= volume_data;
                vol_ptr               <= vol_ptr + 3'd1;
                vol_avg               <= vol_sum[14:3]; // divide by 8
            end

            // Update order pressure counters
            if (is_buy)
                buy_order_count  <= (buy_order_count < 4'hF) ? buy_order_count + 4'd1 : 4'hF;
            if (is_sell)
                sell_order_count <= (sell_order_count < 4'hF) ? sell_order_count + 4'd1 : 4'hF;

            // Trade velocity window
            if (match_valid)
                match_counter <= (match_counter < 6'h3F) ? match_counter + 6'd1 : 6'h3F;

            window_timer <= window_timer + 8'd1;
            if (window_timer == 8'hFF) begin
                match_rate    <= match_counter;
                match_counter <= 6'd0;
                // Slowly decay order counts to avoid stale data
                buy_order_count  <= buy_order_count >> 1;
                sell_order_count <= sell_order_count >> 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // COMBINATIONAL PARALLEL DETECTORS (all evaluate same cycle)
    // ---------------------------------------------------------------

    // Thresholds — driven by config register via top-level (tunable live at demo)
    // spike_thresh and flash_thresh are inputs; others remain fixed
    localparam VOL_SURGE_MULT  = 2;
    localparam VELOCITY_THRESH = 6'd30;
    localparam VOL_DRY_DIV     = 4;

    // [0] Price Spike
    wire [11:0] price_delta = (current_price > prev_price) ?
                               current_price - prev_price :
                               prev_price - current_price;
    wire det_spike = (price_delta > spike_thresh);

    // [1] Volume Surge
    wire [12:0] vol_surge_thresh = {1'b0, vol_avg} << VOL_SURGE_MULT;
    wire det_vol_surge = (vol_avg > 12'd0) &&
                         ({1'b0, current_volume} > vol_surge_thresh);

    // [2] Trade Velocity
    wire det_velocity = (match_rate > VELOCITY_THRESH);

    // [3] Volatility (MAD-based)
    wire [11:0] vol_deviation = (price_delta > price_mad) ?
                                 price_delta - price_mad : 12'd0;
    wire det_volatility = (price_mad > 12'd0) &&
                          (vol_deviation > (price_mad << 2));

    // [4] Volume Drying
    wire [11:0] vol_dry_thresh = (vol_avg >> VOL_DRY_DIV);
    wire det_vol_dry = (vol_avg > 12'd10) &&  // only when baseline established
                       (current_volume < vol_dry_thresh);

    // [5] Spread Widening (using bid/ask order counts as proxy)
    //     Wide spread = few orders on one side
    wire det_spread = (buy_order_count == 4'd0 && sell_order_count > 4'd2) ||
                      (sell_order_count == 4'd0 && buy_order_count > 4'd2);

    // [6] Order Imbalance (3:1 ratio)
    wire det_imbalance = (buy_order_count > 4'd0 && sell_order_count > 4'd0) &&
                         ((buy_order_count > (sell_order_count << 2)) ||
                          (sell_order_count > (buy_order_count << 2)));

    // [7] Flash Crash - CRITICAL: price dropped >40 from established average
    wire [11:0] price_drop = (price_avg > current_price) ?
                              price_avg - current_price : 12'd0;
    wire det_flash = (price_avg > 12'd20) && (price_drop > flash_thresh);

    // Bundle all detector outputs
    assign alert_bitmap = {det_flash,
                           det_volatility,
                           det_spread,
                           det_imbalance,
                           det_velocity,
                           det_vol_surge,
                           det_vol_dry,
                           det_spike};

    // ---------------------------------------------------------------
    // Priority encoder (highest priority = most dangerous)
    // ---------------------------------------------------------------
    assign alert_any = |alert_bitmap;

    // Priority: Flash(7) > Volatility(6) > Spread(5) > Imbalance(4)
    //         > Velocity(3) > VolSurge(2) > VolDry(1) > Spike(0)
    assign alert_priority = det_flash      ? 3'd7 :
                            det_volatility ? 3'd6 :
                            det_spread     ? 3'd5 :
                            det_imbalance  ? 3'd4 :
                            det_velocity   ? 3'd3 :
                            det_vol_surge  ? 3'd2 :
                            det_vol_dry    ? 3'd1 :
                            det_spike      ? 3'd0 : 3'd0;

    assign alert_type = det_flash      ? 3'd7 :
                        det_volatility ? 3'd6 :
                        det_spread     ? 3'd5 :
                        det_imbalance  ? 3'd4 :
                        det_velocity   ? 3'd3 :
                        det_vol_surge  ? 3'd2 :
                        det_vol_dry    ? 3'd1 :
                        det_spike      ? 3'd0 : 3'd0;

endmodule