#!/bin/bash
# Downloads the free 1-minute data used in the study (Oanda M1 mid prices 2005-2020,
# Bitstamp BTC 2012-2018, from github.com/FutureSharks/financial-data, ~5 GB) and
# converts it to compact .npz files in $PDH_DATA.
set -e
PDH_DATA=${PDH_DATA:-$(dirname "$0")/data}
mkdir -p "$PDH_DATA"
SRC=${SRC:-/tmp/financial-data}
[ -d "$SRC" ] || git clone --depth 1 https://github.com/FutureSharks/financial-data "$SRC"
for ins in NAS100_USD SPX500_USD US2000_USD UK100_GBP JP225_USD XAU_USD WTICO_USD EUR_USD GBP_USD USD_CAD AUD_USD EUR_JPY; do
  python3 "$(dirname "$0")/convert.py" "$SRC/pyfinancialdata/data/currencies/oanda/$ins" "$PDH_DATA/$ins.npz"
done
python3 "$(dirname "$0")/convert.py" "$SRC/pyfinancialdata/data/cryptocurrencies/bitstamp/BTC_USD" "$PDH_DATA/BTC_USD.npz"
