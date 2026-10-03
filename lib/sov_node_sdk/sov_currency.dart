// lib/sov_node_sdk/sov_currency.dart
// ─────────────────────────────────────────────────────────────────────────────
// SOV currency display helpers.
//
// SovCurrency provides:
//   • formatSov()       — "⟡ 12.500000" style string
//   • localValue()      — estimated local-currency equivalent
//   • autoDetect()      — locale → default currency code
//   • allCurrencies     — list of 30 supported currencies
//   • symbol            — the ⟡ SOV symbol
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:io';

class _CurrencyInfo {
  final String code;
  final String name;
  final String symbol;
  // Approximate USD exchange rate (1 USD = X local currency).
  // Used only when the network hasn't broadcast a sov_usd_rate yet.
  final double usdRate;

  const _CurrencyInfo({
    required this.code,
    required this.name,
    required this.symbol,
    required this.usdRate,
  });
}

// ─────────────────────────────────────────────────────────────────────────────

class SovCurrency {
  SovCurrency._();

  /// The canonical SOV symbol.
  static const String symbol = '⟡';

  /// SharedPreferences key for the user's chosen currency code.
  static const String prefKey = 'display_currency_code';

  // ── 30 supported currencies ───────────────────────────────────────────────

  static const List<_CurrencyInfo> _currencies = [
    _CurrencyInfo(code: 'USD', name: 'US Dollar',            symbol: '\$',   usdRate:  1.00),
    _CurrencyInfo(code: 'EUR', name: 'Euro',                 symbol: '€',   usdRate:  0.93),
    _CurrencyInfo(code: 'GBP', name: 'British Pound',        symbol: '£',   usdRate:  0.79),
    _CurrencyInfo(code: 'JPY', name: 'Japanese Yen',         symbol: '¥',   usdRate:  155.0),
    _CurrencyInfo(code: 'CNY', name: 'Chinese Yuan',         symbol: '¥',   usdRate:  7.24),
    _CurrencyInfo(code: 'INR', name: 'Indian Rupee',         symbol: '₹',   usdRate:  83.5),
    _CurrencyInfo(code: 'NGN', name: 'Nigerian Naira',       symbol: '₦',   usdRate:  1550.0),
    _CurrencyInfo(code: 'ZAR', name: 'South African Rand',   symbol: 'R',   usdRate:  18.5),
    _CurrencyInfo(code: 'KES', name: 'Kenyan Shilling',      symbol: 'KSh', usdRate:  130.0),
    _CurrencyInfo(code: 'GHS', name: 'Ghanaian Cedi',        symbol: 'GH₵', usdRate:  15.8),
    _CurrencyInfo(code: 'ETB', name: 'Ethiopian Birr',       symbol: 'Br',  usdRate:  57.0),
    _CurrencyInfo(code: 'TZS', name: 'Tanzanian Shilling',   symbol: 'TSh', usdRate:  2680.0),
    _CurrencyInfo(code: 'UGX', name: 'Ugandan Shilling',     symbol: 'USh', usdRate:  3820.0),
    _CurrencyInfo(code: 'XOF', name: 'West African CFA',     symbol: 'CFA', usdRate:  610.0),
    _CurrencyInfo(code: 'MAD', name: 'Moroccan Dirham',      symbol: 'DH',  usdRate:  10.1),
    _CurrencyInfo(code: 'EGP', name: 'Egyptian Pound',       symbol: 'E£',  usdRate:  31.0),
    _CurrencyInfo(code: 'BRL', name: 'Brazilian Real',       symbol: 'R\$', usdRate:  5.05),
    _CurrencyInfo(code: 'MXN', name: 'Mexican Peso',         symbol: 'Mex\$',usdRate: 17.2),
    _CurrencyInfo(code: 'ARS', name: 'Argentine Peso',       symbol: 'AR\$',usdRate:  930.0),
    _CurrencyInfo(code: 'COP', name: 'Colombian Peso',       symbol: 'COL\$',usdRate: 4100.0),
    _CurrencyInfo(code: 'CAD', name: 'Canadian Dollar',      symbol: 'CA\$',usdRate:  1.37),
    _CurrencyInfo(code: 'AUD', name: 'Australian Dollar',    symbol: 'AU\$',usdRate:  1.55),
    _CurrencyInfo(code: 'SGD', name: 'Singapore Dollar',     symbol: 'S\$', usdRate:  1.35),
    _CurrencyInfo(code: 'SAR', name: 'Saudi Riyal',          symbol: '﷼',   usdRate:  3.75),
    _CurrencyInfo(code: 'AED', name: 'UAE Dirham',           symbol: 'د.إ', usdRate:  3.67),
    _CurrencyInfo(code: 'PKR', name: 'Pakistani Rupee',      symbol: '₨',   usdRate:  278.0),
    _CurrencyInfo(code: 'BDT', name: 'Bangladeshi Taka',     symbol: '৳',   usdRate:  110.0),
    _CurrencyInfo(code: 'PHP', name: 'Philippine Peso',      symbol: '₱',   usdRate:  57.0),
    _CurrencyInfo(code: 'IDR', name: 'Indonesian Rupiah',    symbol: 'Rp',  usdRate:  15600.0),
    _CurrencyInfo(code: 'TRY', name: 'Turkish Lira',         symbol: '₺',   usdRate:  32.5),
  ];

  /// All 30 supported currency codes and display names.
  static List<Map<String, String>> get allCurrencies => _currencies
      .map((c) => {'code': c.code, 'name': c.name, 'symbol': c.symbol})
      .toList();

  // ── Look-up helpers ───────────────────────────────────────────────────────

  static _CurrencyInfo _info(String code) =>
      _currencies.firstWhere((c) => c.code == code,
          orElse: () => _currencies.first);

  /// Currency symbol for [code] (e.g. "$" for USD).
  static String symbolFor(String code) => _info(code).symbol;

  /// Display name for [code] (e.g. "US Dollar").
  static String nameFor(String code) => _info(code).name;

  // ── SOV formatting ────────────────────────────────────────────────────────

  /// Format a SOV amount as "⟡ 12.500000".
  /// Pass [seeds] in micro-SOV (1 SOV = 1 000 000 seeds).
  static String formatSeeds(int seeds) {
    final sov = seeds / 1000000.0;
    return '$symbol ${sov.toStringAsFixed(6)}';
  }

  /// Format a SOV amount (as whole SOV) as "⟡ 12.500000".
  static String formatSov(double sov) =>
      '$symbol ${sov.toStringAsFixed(6)}';

  // ── Local currency display ────────────────────────────────────────────────

  /// Return a human-readable local-currency estimate for [sov] SOV.
  ///
  /// [sovUsdRate] — relay's current SOV/USD rate (0 if unknown).
  /// [currencyCode] — ISO 4217 code, e.g. "NGN". Falls back to "USD".
  ///
  /// Returns e.g. "≈ ₦ 1,550.00" or empty string if rate unknown.
  static String localValue(
      double sov, double sovUsdRate, String currencyCode) {
    if (sovUsdRate <= 0) return '';
    final info    = _info(currencyCode);
    final local   = sov * sovUsdRate * info.usdRate;
    final display = _formatLocal(local, info);
    return '≈ $display';
  }

  /// Same as [localValue] but takes seeds input.
  static String localValueSeeds(
      int seeds, double sovUsdRate, String currencyCode) {
    return localValue(seeds / 1000000.0, sovUsdRate, currencyCode);
  }

  static String _formatLocal(double amount, _CurrencyInfo info) {
    // Choose decimal places by magnitude
    String formatted;
    if (amount >= 1000) {
      formatted = amount.toStringAsFixed(0)
          .replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
              (m) => '${m[1]},');
    } else if (amount >= 1) {
      formatted = amount.toStringAsFixed(2);
    } else {
      formatted = amount.toStringAsFixed(4);
    }
    return '${info.symbol} $formatted';
  }

  // ── Auto-detect from device locale ───────────────────────────────────────

  /// Guess a reasonable default currency code from the device locale.
  /// Falls back to 'USD' for any unknown locale.
  static String autoDetect() {
    try {
      final locale = Platform.localeName; // e.g. "en_NG", "fr_CI"
      return _localeToCode(locale);
    } catch (_) {
      return 'USD';
    }
  }

  static String _localeToCode(String locale) {
    final country = locale.contains('_') ? locale.split('_').last.toUpperCase() : '';
    switch (country) {
      case 'US': return 'USD';
      case 'GB': return 'GBP';
      case 'DE': case 'FR': case 'IT': case 'ES': case 'PT':
      case 'NL': case 'BE': case 'AT': case 'IE': case 'FI':
      case 'GR': case 'SK': case 'SI': case 'LT': case 'LV': case 'EE': return 'EUR';
      case 'JP': return 'JPY';
      case 'CN': case 'TW': case 'HK': return 'CNY';
      case 'IN': return 'INR';
      case 'NG': return 'NGN';
      case 'ZA': return 'ZAR';
      case 'KE': return 'KES';
      case 'GH': return 'GHS';
      case 'ET': return 'ETB';
      case 'TZ': return 'TZS';
      case 'UG': return 'UGX';
      case 'SN': case 'CI': case 'ML': case 'BF': case 'BJ': case 'TG':
      case 'GW': case 'NE': return 'XOF';
      case 'MA': return 'MAD';
      case 'EG': return 'EGP';
      case 'BR': return 'BRL';
      case 'MX': return 'MXN';
      case 'AR': return 'ARS';
      case 'CO': return 'COP';
      case 'CA': return 'CAD';
      case 'AU': return 'AUD';
      case 'SG': return 'SGD';
      case 'SA': return 'SAR';
      case 'AE': return 'AED';
      case 'PK': return 'PKR';
      case 'BD': return 'BDT';
      case 'PH': return 'PHP';
      case 'ID': return 'IDR';
      case 'TR': return 'TRY';
      default:   return 'USD';
    }
  }
}
