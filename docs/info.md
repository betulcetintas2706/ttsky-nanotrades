# NanoTrade — HFT ASIC with ML Anomaly Detection

## How it works

NanoTrade is a real-time ASIC combining order book matching with 
triple-path anomaly detection:

- **Rule-based detectors** (1 cycle = 20 ns): 8 parallel detectors 
  for flash crash, volume surge, quote stuffing, order imbalance, 
  price spike, volatility, volume dry, and spread widening
- **ML pipeline** (4 cycles = 80 ns): 16→8→6 MLP neural network 
  classifies market state into 6 classes
- **Cascade detector**: recognises multi-event sequences including 
  the 2010 Flash Crash TRIPLE pattern (VOLUME_SURGE → PRICE_SPIKE → 
  FLASH_CRASH)
- **ML-controlled circuit breaker**: automatically PAUSE, THROTTLE, 
  or WIDEN the order book based on ML class and confidence

## How to use

Send data via ui_in[7:6] type bits and ui_in[5:0] payload:
- 00 = price update
- 01 = volume update
- 10 = buy order
- 11 = sell order

Monitor outputs:
- uo_out[7] = global alert flag
- uo_out[6:4] = alert priority (7=critical)
- uo_out[2:0] = alert type (7=flash crash)
- uio_out[1] = cascade alert flag

## External hardware

None required. Standalone ASIC.
