// lib/sov_node_sdk/sov_id_v2.dart
// V2 Sovereign ID — MCC-indexed disc lookup
// Format: SOV-XXXXXXXXXXXXXXXX (16 hex chars, MCC digits at positions 2–4)
import 'dart:io';
import 'package:flutter/services.dart';

class SovIdV2 {

  // MCC position in the 16-char hex string (zero-indexed)
  // Positions 2, 3, 4 contain the 3-digit MCC
  static const int mccStart = 2;
  static const int mccEnd   = 5; // exclusive

  // ── Complete MCC → country name mapping ────────────────────────────────
  // Bundled in app — no server needed. Key: MCC string, Value: country name.
  static const Map<String, String> mccCountry = {
    '202': 'Greece',          '204': 'Netherlands',      '206': 'Belgium',
    '208': 'France',          '212': 'Monaco',           '213': 'Andorra',
    '214': 'Spain',           '216': 'Hungary',          '218': 'Bosnia',
    '219': 'Croatia',         '220': 'Serbia',           '222': 'Italy',
    '226': 'Romania',         '228': 'Switzerland',      '230': 'Czech Republic',
    '231': 'Slovakia',        '232': 'Austria',          '234': 'United Kingdom',
    '238': 'Denmark',         '240': 'Sweden',           '242': 'Norway',
    '244': 'Finland',         '246': 'Lithuania',        '247': 'Latvia',
    '248': 'Estonia',         '250': 'Russia',           '255': 'Ukraine',
    '257': 'Belarus',         '259': 'Moldova',          '260': 'Poland',
    '262': 'Germany',         '266': 'Gibraltar',        '268': 'Portugal',
    '270': 'Luxembourg',      '272': 'Ireland',          '274': 'Iceland',
    '276': 'Albania',         '278': 'Malta',            '280': 'Cyprus',
    '282': 'Georgia',         '283': 'Armenia',          '284': 'Bulgaria',
    '286': 'Turkey',          '288': 'Faroe Islands',    '290': 'Greenland',
    '293': 'Slovenia',        '294': 'North Macedonia',  '295': 'Liechtenstein',
    '302': 'Canada',          '308': 'Saint Pierre',
    '310': 'United States',   '311': 'United States',
    '312': 'United States',   '313': 'United States',
    '314': 'United States',   '315': 'United States',
    '316': 'United States',
    '330': 'Puerto Rico',     '334': 'Mexico',           '338': 'Jamaica',
    '340': 'Guadeloupe',      '342': 'Barbados',         '344': 'Antigua',
    '346': 'Cayman Islands',  '348': 'British Virgin Islands',
    '350': 'Bermuda',         '352': 'Grenada',          '354': 'Montserrat',
    '356': 'Saint Kitts',     '358': 'Saint Lucia',
    '360': 'Saint Vincent',   '362': 'Netherlands Antilles',
    '363': 'Aruba',           '364': 'Bahamas',          '365': 'Anguilla',
    '366': 'Dominica',        '368': 'Cuba',             '370': 'Dominican Republic',
    '372': 'Haiti',           '374': 'Trinidad and Tobago',
    '376': 'Turks and Caicos',
    '400': 'Azerbaijan',      '401': 'Kazakhstan',       '402': 'Bhutan',
    '404': 'India',           '405': 'India',            '410': 'Pakistan',
    '412': 'Afghanistan',     '413': 'Sri Lanka',        '414': 'Myanmar',
    '415': 'Lebanon',         '416': 'Jordan',           '417': 'Syria',
    '418': 'Iraq',            '419': 'Kuwait',           '420': 'Saudi Arabia',
    '421': 'Yemen',           '422': 'Oman',             '424': 'UAE',
    '425': 'Israel',          '426': 'Bahrain',          '427': 'Qatar',
    '428': 'Mongolia',        '429': 'Nepal',            '430': 'UAE',
    '432': 'Iran',            '434': 'Uzbekistan',       '436': 'Tajikistan',
    '437': 'Kyrgyzstan',      '438': 'Turkmenistan',     '440': 'Japan',
    '441': 'Japan',           '450': 'South Korea',      '452': 'Vietnam',
    '454': 'Hong Kong',       '455': 'Macao',            '456': 'Cambodia',
    '457': 'Laos',            '460': 'China',            '461': 'China',
    '466': 'Taiwan',          '467': 'North Korea',      '470': 'Bangladesh',
    '472': 'Maldives',        '502': 'Malaysia',         '505': 'Australia',
    '510': 'Indonesia',       '514': 'East Timor',       '515': 'Philippines',
    '520': 'Thailand',        '525': 'Singapore',        '528': 'Brunei',
    '530': 'New Zealand',     '536': 'Nauru',            '537': 'Papua New Guinea',
    '539': 'Tonga',           '540': 'Solomon Islands',  '541': 'Vanuatu',
    '542': 'Fiji',            '543': 'Wallis and Futuna','544': 'American Samoa',
    '545': 'Kiribati',        '546': 'New Caledonia',    '547': 'French Polynesia',
    '548': 'Cook Islands',    '549': 'Samoa',            '550': 'Micronesia',
    '602': 'Egypt',           '603': 'Algeria',          '604': 'Morocco',
    '605': 'Tunisia',         '606': 'Libya',            '607': 'Gambia',
    '608': 'Senegal',         '609': 'Mauritania',       '610': 'Mali',
    '611': 'Guinea',          '612': 'Ivory Coast',      '613': 'Burkina Faso',
    '614': 'Niger',           '615': 'Togo',             '616': 'Benin',
    '617': 'Mauritius',       '618': 'Liberia',          '619': 'Sierra Leone',
    '620': 'Ghana',           '621': 'Nigeria',          '622': 'Chad',
    '623': 'Central African Republic', '624': 'Cameroon',
    '625': 'Cape Verde',      '626': 'Sao Tome',         '627': 'Equatorial Guinea',
    '628': 'Gabon',           '629': 'Congo',            '630': 'DR Congo',
    '631': 'Angola',          '632': 'Guinea-Bissau',    '633': 'Seychelles',
    '634': 'Sudan',           '635': 'Rwanda',           '636': 'Ethiopia',
    '637': 'Somalia',         '638': 'Djibouti',         '639': 'Kenya',
    '640': 'Tanzania',        '641': 'Uganda',           '642': 'Burundi',
    '643': 'Mozambique',      '645': 'Zambia',           '646': 'Madagascar',
    '647': 'Reunion',         '648': 'Zimbabwe',         '649': 'Namibia',
    '650': 'Malawi',          '651': 'Lesotho',          '652': 'Botswana',
    '653': 'Swaziland',       '654': 'Comoros',          '655': 'South Africa',
    '657': 'Eritrea',         '659': 'South Sudan',      '702': 'Belize',
    '704': 'Guatemala',       '706': 'El Salvador',      '708': 'Honduras',
    '710': 'Nicaragua',       '712': 'Costa Rica',       '714': 'Panama',
    '716': 'Peru',            '722': 'Argentina',        '724': 'Brazil',
    '730': 'Chile',           '732': 'Colombia',         '734': 'Venezuela',
    '736': 'Bolivia',         '738': 'Guyana',           '740': 'Ecuador',
    '744': 'Paraguay',        '746': 'Suriname',         '748': 'Uruguay',
    '750': 'Falkland Islands',
    '999': 'International',   // fallback — no SIM, no recognisable locale
  };

  // ── ISO country code → MCC mapping (locale fallback) ───────────────────
  static const Map<String, String> isoToMcc = {
    'GR': '202', 'NL': '204', 'BE': '206', 'FR': '208',
    'MC': '212', 'AD': '213', 'ES': '214', 'HU': '216',
    'BA': '218', 'HR': '219', 'RS': '220', 'IT': '222',
    'RO': '226', 'CH': '228', 'CZ': '230', 'SK': '231',
    'AT': '232', 'GB': '234', 'DK': '238', 'SE': '240',
    'NO': '242', 'FI': '244', 'LT': '246', 'LV': '247',
    'EE': '248', 'RU': '250', 'UA': '255', 'BY': '257',
    'MD': '259', 'PL': '260', 'DE': '262', 'GI': '266',
    'PT': '268', 'LU': '270', 'IE': '272', 'IS': '274',
    'AL': '276', 'MT': '278', 'CY': '280', 'GE': '282',
    'AM': '283', 'BG': '284', 'TR': '286', 'SI': '293',
    'MK': '294', 'LI': '295', 'CA': '302', 'US': '310',
    'PR': '330', 'MX': '334', 'JM': '338', 'GP': '340',
    'BB': '342', 'AG': '344', 'KY': '346', 'VG': '348',
    'BM': '350', 'GD': '352', 'MS': '354', 'KN': '356',
    'LC': '358', 'VC': '360', 'AN': '362', 'AW': '363',
    'BS': '364', 'AI': '365', 'DM': '366', 'CU': '368',
    'DO': '370', 'HT': '372', 'TT': '374', 'TC': '376',
    'AZ': '400', 'KZ': '401', 'BT': '402', 'IN': '404',
    'PK': '410', 'AF': '412', 'LK': '413', 'MM': '414',
    'LB': '415', 'JO': '416', 'SY': '417', 'IQ': '418',
    'KW': '419', 'SA': '420', 'YE': '421', 'OM': '422',
    'AE': '424', 'IL': '425', 'BH': '426', 'QA': '427',
    'MN': '428', 'NP': '429', 'IR': '432', 'UZ': '434',
    'TJ': '436', 'KG': '437', 'TM': '438', 'JP': '440',
    'KR': '450', 'VN': '452', 'HK': '454', 'MO': '455',
    'KH': '456', 'LA': '457', 'CN': '460', 'TW': '466',
    'KP': '467', 'BD': '470', 'MV': '472', 'MY': '502',
    'AU': '505', 'ID': '510', 'TL': '514', 'PH': '515',
    'TH': '520', 'SG': '525', 'BN': '528', 'NZ': '530',
    'PG': '537', 'TO': '539', 'SB': '540', 'VU': '541',
    'FJ': '542', 'KI': '545', 'NC': '546', 'PF': '547',
    'CK': '548', 'WS': '549', 'FM': '550', 'EG': '602',
    'DZ': '603', 'MA': '604', 'TN': '605', 'LY': '606',
    'GM': '607', 'SN': '608', 'MR': '609', 'ML': '610',
    'GN': '611', 'CI': '612', 'BF': '613', 'NE': '614',
    'TG': '615', 'BJ': '616', 'MU': '617', 'LR': '618',
    'SL': '619', 'GH': '620', 'NG': '621', 'TD': '622',
    'CF': '623', 'CM': '624', 'CV': '625', 'ST': '626',
    'GQ': '627', 'GA': '628', 'CG': '629', 'CD': '630',
    'AO': '631', 'GW': '632', 'SC': '633', 'SD': '634',
    'RW': '635', 'ET': '636', 'SO': '637', 'DJ': '638',
    'KE': '639', 'TZ': '640', 'UG': '641', 'BI': '642',
    'MZ': '643', 'ZM': '645', 'MG': '646', 'RE': '647',
    'ZW': '648', 'NA': '649', 'MW': '650', 'LS': '651',
    'BW': '652', 'SZ': '653', 'KM': '654', 'ZA': '655',
    'ER': '657', 'SS': '659', 'BZ': '702', 'GT': '704',
    'SV': '706', 'HN': '708', 'NI': '710', 'CR': '712',
    'PA': '714', 'PE': '716', 'AR': '722', 'BR': '724',
    'CL': '730', 'CO': '732', 'VE': '734', 'BO': '736',
    'GY': '738', 'EC': '740', 'PY': '744', 'SR': '746',
    'UY': '748', 'FK': '750',
  };

  // ── Public API ─────────────────────────────────────────────────────────

  /// Get MCC from device SIM card.
  /// Falls back to locale country code if no SIM.
  /// Falls back to '999' (international) if everything fails.
  /// No server call. No permission beyond what app already has.
  static Future<String> getDeviceMcc() async {
    // 1. Try SIM card hardware
    try {
      final simMcc = await _readSimMcc();
      if (simMcc != null && simMcc.length == 3) return simMcc;
    } catch (_) {}

    // 2. Fallback: device locale (e.g. "en_NG" → "NG" → "621")
    try {
      final locale = Platform.localeName; // e.g. "en_NG" or "en_US"
      final parts  = locale.split('_');
      if (parts.length >= 2) {
        final isoCountry = parts.last.toUpperCase();
        final mcc = isoToMcc[isoCountry];
        if (mcc != null) return mcc;
      }
    } catch (_) {}

    // 3. Final fallback: international segment
    return '999';
  }

  /// Generate a V2 Sovereign ID.
  /// Embeds MCC at positions 2–4 of the 16 hex characters.
  ///
  /// [masterKeyHash] — full SHA-256 hex hash from BCH enrollment
  /// [mcc]          — 3-digit string from [getDeviceMcc]
  ///
  /// Output: SOV-XXXXXXXXXXXXXXXX
  /// Layout: pos 0–1 = hash[0:2], pos 2–4 = MCC, pos 5–15 = hash[2:13]
  static String generate(String masterKeyHash, String mcc) {
    final hash      = masterKeyHash.toUpperCase();
    final mccPadded = mcc.padLeft(3, '0');
    // pos: 0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
    //      H  H  M  M  M  H  H  H  H  H  H  H  H  H  H  H
    final part1 = hash.substring(0, 2);   // hash positions 0–1
    final part2 = mccPadded;              // MCC at positions 2–4
    final part3 = hash.substring(2, 13); // hash positions 2–12 → ID positions 5–15
    return 'SOV-$part1$part2$part3';
  }

  /// Extract MCC from a V2 Sovereign ID.
  /// Returns null if the ID is V1 format (hex chars at positions 2–4, no MCC).
  static String? extractMcc(String sovId) {
    if (!sovId.startsWith('SOV-')) return null;
    final id = sovId.substring(4); // strip SOV-
    if (id.length != 16) return null;
    final mcc = id.substring(mccStart, mccEnd);
    // V2 IDs have 3 decimal digits here; V1 IDs have hex chars (A–F present)
    if (RegExp(r'^\d{3}$').hasMatch(mcc)) return mcc;
    return null; // V1 ID
  }

  /// Get country name from any Sovereign ID (V1 or V2).
  static String getCountryName(String sovId) {
    final mcc = extractMcc(sovId);
    if (mcc == null) return 'Unknown';
    return mccCountry[mcc] ?? 'Unknown';
  }

  /// Returns true if [sovId] is a V2 ID (has valid MCC embedded).
  static bool isV2(String sovId) => extractMcc(sovId) != null;

  /// Validate a Sovereign ID (V1 or V2).
  static bool isValid(String sovId) {
    if (!sovId.startsWith('SOV-')) return false;
    final id = sovId.substring(4);
    if (id.length != 16) return false;
    return RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(id);
  }

  // ── Private ────────────────────────────────────────────────────────────

  /// Read MCC directly from SIM hardware via native Android platform channel.
  /// Returns a 3-digit string or null if no SIM / not available / permission denied.
  /// On Android 10+ (API 29+) no permission is required — reads silently.
  static Future<String?> _readSimMcc() async {
    try {
      const platform = MethodChannel('network.sov.node/sim');
      final String? mcc = await platform.invokeMethod<String>('getMcc');
      if (mcc != null &&
          mcc.length == 3 &&
          RegExp(r'^\d{3}$').hasMatch(mcc)) {
        return mcc;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
