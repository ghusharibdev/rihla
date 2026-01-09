import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'data/airports_data.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive_ce.dart';
import 'dart:ui';
import 'dart:async';
import 'package:flutter_map/flutter_map.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:latlong2/latlong.dart';

// --- FIX: Extension for Offset.normalize() ---
extension OffsetExtension on Offset {
  /// Returns a new Offset object with the same direction but a magnitude of 1.
  Offset normalize() {
    final magnitude = sqrt(dx * dx + dy * dy);
    // Return Offset.zero if magnitude is zero to prevent division by zero.
    if (magnitude == 0) return Offset.zero;
    return Offset(dx / magnitude, dy / magnitude);
  }
}

// --- RESPONSIVE DESIGN MIXINS ---
mixin ResponsiveMixin {
  bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1200;
  bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1200;

  double responsiveValue(
    BuildContext context, {
    required double mobile,
    double? tablet,
    double? desktop,
  }) {
    if (isDesktop(context)) return desktop ?? tablet ?? mobile;
    if (isTablet(context)) return tablet ?? mobile;
    return mobile;
  }

  int responsiveGridCount(BuildContext context) {
    if (isDesktop(context)) return 4;
    if (isTablet(context)) return 3;
    return 2;
  }
}

class SearchResultItem {
  final String title;
  final String subtitle;
  final String icon;
  final Color iconColor;
  final String type; // 'flight', 'route', 'airport', 'airline'
  final dynamic data; // Could be RihlaFlightData, Airport, etc.

  SearchResultItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.type,
    this.data,
  });
}

// Update the Destination and Deal models
class Destination {
  final String title;
  final String imageUrl;

  Destination({required this.title, required this.imageUrl});

  factory Destination.fromJson(Map<String, dynamic> json) {
    String imageUrl = json['image'] ?? '';

    // Clean markdown formatting
    imageUrl = _cleanImageUrl(imageUrl);

    // If it's just a city name without URL, construct CDN URL
    if (imageUrl.isNotEmpty && !imageUrl.startsWith('http')) {
      // Check if it's a simple city name (no dots, no slashes)
      if (!imageUrl.contains('.') && !imageUrl.contains('/')) {
        imageUrl =
            'https://cdn.rihla.cc/city-images/${imageUrl.toLowerCase()}.jpg';
      }
    }

    // Fix http to https and fix broken URLs
    if (imageUrl.startsWith('http://')) {
      imageUrl = imageUrl.replaceFirst('http://', 'https://');
    }

    // Fix missing .cc domain in some URLs
    if (imageUrl.contains('https://cdn.rihla/city-images/')) {
      imageUrl = imageUrl.replaceFirst(
        'https://cdn.rihla/city-images/',
        'https://cdn.rihla.cc/city-images/',
      );
    }

    return Destination(
      title: json['title'] ?? 'Unknown Destination',
      imageUrl: imageUrl,
    );
  }

  static String _cleanImageUrl(String url) {
    // Remove markdown format: [url](url) -> url
    if (url.contains('[') &&
        url.contains(']') &&
        url.contains('(') &&
        url.contains(')')) {
      final regex = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
      final match = regex.firstMatch(url);
      if (match != null) {
        return match.group(2) ?? url;
      }
    }
    return url;
  }
}

class Deal {
  final String name;
  final String imageUrl;

  Deal({required this.name, required this.imageUrl});

  factory Deal.fromJson(Map<String, dynamic> json) {
    String imageUrl = json['image'] ?? '';

    // Use the same cleaning logic as Destination
    imageUrl = Destination._cleanImageUrl(imageUrl);

    // If it's just a city name without URL, construct CDN URL
    if (imageUrl.isNotEmpty && !imageUrl.startsWith('http')) {
      if (!imageUrl.contains('.') && !imageUrl.contains('/')) {
        imageUrl =
            'https://cdn.rihla.cc/city-images/${imageUrl.toLowerCase()}.jpg';
      }
    }

    // Fix http to https and fix broken URLs
    if (imageUrl.startsWith('http://')) {
      imageUrl = imageUrl.replaceFirst('http://', 'https://');
    }

    // Fix missing .cc domain
    if (imageUrl.contains('https://cdn.rihla/city-images/')) {
      imageUrl = imageUrl.replaceFirst(
        'https://cdn.rihla/city-images/',
        'https://cdn.rihla.cc/city-images/',
      );
    }

    return Deal(name: json['name'] ?? 'Unknown Deal', imageUrl: imageUrl);
  }
}
// Update the Flight class (around line 115-147) to include proper date handling:

class Flight {
  final String city;
  final String route;
  final String flightNumber;
  final String status;
  final String airline;
  final String departureTime;
  final String arrivalTime;
  final String duration;
  final String aircraft;
  final DateTime flightDate;
  final String origin;
  final String destination;
  final String? actualDepartureDate; // Add this field
  final String? lastChecked; // Add this field

  Flight({
    required this.city,
    required this.route,
    required this.flightNumber,
    required this.status,
    this.airline = '',
    this.departureTime = '',
    this.arrivalTime = '',
    this.duration = '',
    this.aircraft = '',
    this.origin = '',
    this.destination = '',
    DateTime? flightDate,
    this.actualDepartureDate,
    this.lastChecked,
  }) : flightDate = flightDate ?? DateTime.now();

  // Helper method to get display date
  String get displayDate {
    if (actualDepartureDate != null) {
      return _formatDateString(actualDepartureDate!);
    }
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[flightDate.month - 1]} ${flightDate.day}';
  }

  String _formatDateString(String dateStr) {
    try {
      // Handle different date formats from API
      if (dateStr.contains('-')) {
        final parts = dateStr.split('-');
        if (parts.length >= 3) {
          final year = int.parse(parts[0]);
          final month = int.parse(parts[1]);
          final day = int.parse(parts[2]);
          final months = [
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec',
          ];
          return '${months[month - 1]} $day, $year';
        }
      }
      return dateStr;
    } catch (e) {
      return dateStr;
    }
  }
}

class FlightAdapter extends TypeAdapter<Flight> {
  @override
  final int typeId = 0; // Choose a unique ID for Flight class

  @override
  Flight read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(reader.readMap());

    return Flight(
      city: map['city'] as String,
      route: map['route'] as String,
      flightNumber: map['flightNumber'] as String,
      status: map['status'] as String,
      airline: map['airline'] as String,
      departureTime: map['departureTime'] as String,
      arrivalTime: map['arrivalTime'] as String,
      duration: map['duration'] as String,
      aircraft: map['aircraft'] as String,
      origin: map['origin'] as String,
      destination: map['destination'] as String,
      flightDate: DateTime.parse(map['flightDate'] as String),
      actualDepartureDate: map['actualDepartureDate'] as String?,
      lastChecked: map['lastChecked'] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Flight obj) {
    writer.writeMap({
      'city': obj.city,
      'route': obj.route,
      'flightNumber': obj.flightNumber,
      'status': obj.status,
      'airline': obj.airline,
      'departureTime': obj.departureTime,
      'arrivalTime': obj.arrivalTime,
      'duration': obj.duration,
      'aircraft': obj.aircraft,
      'origin': obj.origin,
      'destination': obj.destination,
      'flightDate': obj.flightDate.toIso8601String(),
      'actualDepartureDate': obj.actualDepartureDate,
      'lastChecked': obj.lastChecked,
    });
  }
}

class Airline {
  final String id; // IATA code (e.g., "EY", "QR", "PK")
  final String name;
  final String logo;
  final String lcc; // Low-cost carrier indicator

  Airline({
    required this.id,
    required this.name,
    required this.logo,
    required this.lcc,
  });

  factory Airline.fromJson(Map<String, dynamic> json) {
    return Airline(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      logo: json['logo'] ?? '',
      lcc: json['lcc'] ?? '0',
    );
  }

  bool get isLowCostCarrier => lcc == '1';
}

class AirlineService {
  static List<Airline> _airlines = [];
  static final Map<String, Airline> _airlineByCode = {};
  static final Map<String, Airline> _airlineByName = {};
  static bool _isInitialized = false;

  static Future<void> loadAirlines() async {
    try {
      print('📦 Loading airline data...');

      // Load from your local JSON file
      final String jsonString = await rootBundle.loadString(
        'lib/data/airlines.json',
      );
      final List<dynamic> jsonList = json.decode(jsonString) as List<dynamic>;

      _airlines = jsonList.map((json) => Airline.fromJson(json)).toList();

      // Create lookup maps
      for (final airline in _airlines) {
        if (airline.id.isNotEmpty) {
          // Store by exact ID (e.g., "QR", "AUTOSTRAD")
          _airlineByCode[airline.id] = airline;

          // Also store uppercase version for case-insensitive lookup
          _airlineByCode[airline.id.toUpperCase()] = airline;

          // Store by name for fallback lookup
          if (airline.name.isNotEmpty) {
            _airlineByName[airline.name.toLowerCase()] = airline;
          }

          // For 2-char IATA codes, also store without any modifications
          if (airline.id.length == 2) {
            _airlineByCode[airline.id.toUpperCase()] = airline;
          }
        }
      }

      _isInitialized = true;
      print(
        '✅ Loaded ${_airlines.length} airlines, ${_airlineByCode.length} in lookup map',
      );
      print(
        '📋 Sample airlines loaded: ${_airlines.take(5).map((a) => '${a.id}:${a.name}').toList()}',
      );
    } catch (e) {
      print('❌ Error loading airlines: $e');
      _airlines = [];
      _airlineByCode.clear();
      _airlineByName.clear();
      _isInitialized = false;
    }
  }

  static Airline? getAirlineByCode(String code) {
    if (code.isEmpty || !_isInitialized) return null;

    // Try exact match first
    Airline? airline = _airlineByCode[code];
    if (airline != null) return airline;

    // Try uppercase
    final upperCode = code.toUpperCase();
    airline = _airlineByCode[upperCode];
    if (airline != null) return airline;

    // Try to find by matching partial name
    final knownAirlines = {
      'QR': 'Qatar Airways',
      'EK': 'Emirates',
      'EY': 'Etihad Airways',
      'TK': 'Turkish Airlines',
      'PK': 'Pakistan International Airlines',
      '9P': 'Airblue',
      'PA': 'Airblue',
      'ER': 'SereneAir',
      'SV': 'Saudia',
      'FZ': 'flydubai',
      'GF': 'Gulf Air',
      '6E': 'IndiGo',
      'SQ': 'Singapore Airlines',
      'QF': 'Qantas',
      'XY': 'Flynas',
      'UL': 'SriLankan Airlines',
      'KU': 'Kuwait Airways',
      'OD': 'Batik Air Malaysia',
      'J2': 'Azerbaijan Airlines',
    };

    final airlineName = knownAirlines[code];
    if (airlineName != null) {
      // Try to find by name in our loaded airlines
      return _airlineByName[airlineName.toLowerCase()];
    }

    return null;
  }

  static String getAirlineName(String code) {
    if (code.isEmpty) return 'Unknown Airline';

    final airline = getAirlineByCode(code);
    if (airline != null && airline.name.isNotEmpty) {
      return airline.name;
    }

    // Fallback: known airline codes
    final knownAirlines = {
      'QR': 'Qatar Airways',
      'EK': 'Emirates',
      'EY': 'Etihad Airways',
      'TK': 'Turkish Airlines',
      'PK': 'Pakistan International Airlines',
      '9P': 'Airblue',
      'PA': 'Airblue',
      'ER': 'SereneAir',
      'SV': 'Saudia',
      'FZ': 'flydubai',
      'GF': 'Gulf Air',
      '6E': 'IndiGo',
      'SQ': 'Singapore Airlines',
      'QF': 'Qantas',
      'XY': 'Flynas',
      'UL': 'SriLankan Airlines',
      'KU': 'Kuwait Airways',
      'OD': 'Batik Air Malaysia',
      'J2': 'Azerbaijan Airlines',
    };

    return knownAirlines[code] ?? code;
  }

  static String getAirlineLogoUrl(String code) {
    if (code.isEmpty) return '';

    final airline = getAirlineByCode(code);
    if (airline != null && airline.logo.isNotEmpty) {
      return airline.logo;
    }

    // Fallback 1: Try Kiwi logo service for 2-char IATA codes
    if (code.length == 2) {
      return 'https://images.kiwi.com/airlines/64/$code.png';
    }

    // Fallback 2: Try to construct from known airlines
    final knownLogos = {
      'QR': 'https://images.kiwi.com/airlines/64/QR.png',
      'EK': 'https://images.kiwi.com/airlines/64/EK.png',
      'EY': 'https://images.kiwi.com/airlines/64/EY.png',
      'TK': 'https://images.kiwi.com/airlines/64/TK.png',
      'PK': 'https://images.kiwi.com/airlines/64/PK.png',
      '9P': 'https://images.kiwi.com/airlines/64/9P.png',
      'PA': 'https://images.kiwi.com/airlines/64/PA.png',
      'ER': 'https://images.kiwi.com/airlines/64/ER.png',
      'SV': 'https://images.kiwi.com/airlines/64/SV.png',
      'FZ': 'https://images.kiwi.com/airlines/64/FZ.png',
      'GF': 'https://images.kiwi.com/airlines/64/GF.png',
      '6E': 'https://images.kiwi.com/airlines/64/6E.png',
      'SQ': 'https://images.kiwi.com/airlines/64/SQ.png',
      'QF': 'https://images.kiwi.com/airlines/64/QF.png',
      'XY': 'https://images.kiwi.com/airlines/64/XY.png',
      'UL': 'https://images.kiwi.com/airlines/64/UL.png',
      'KU': 'https://images.kiwi.com/airlines/64/KU.png',
      'OD': 'https://images.kiwi.com/airlines/64/OD.png',
      'J2': 'https://images.kiwi.com/airlines/64/J2.png',
    };

    return knownLogos[code] ?? 'https://images.kiwi.com/airlines/64/XX.png';
  }

  static List<Airline> getPopularAirlines() {
    const popularCodes = [
      'QR',
      'EK',
      'EY',
      'TK',
      'PK',
      '9P',
      'PA',
      'ER',
      'SV',
      'FZ',
      'GF',
      '6E',
      'SQ',
      'QF',
    ];
    return popularCodes
        .map((code) => getAirlineByCode(code))
        .where((airline) => airline != null)
        .cast<Airline>()
        .toList();
  }

  static bool get isInitialized => _isInitialized;
}

class Airport {
  final String name;
  final String code; // IATA code
  final String city;
  final String country;

  Airport({
    required this.name,
    required this.code,
    required this.city,
    required this.country,
  });

  String get displayName => '$city - $code';
  String get fullDescription => '$country - $name ($code)';
}

class RecommendationResponse {
  final List<Destination> destinations;
  final List<Deal> deals;

  RecommendationResponse({required this.destinations, required this.deals});

  factory RecommendationResponse.fromJson(Map<String, dynamic> json) {
    final List<dynamic> destinationList = json['destinations'] ?? [];
    final List<dynamic> dealsList = json['deals'] ?? [];

    return RecommendationResponse(
      destinations: destinationList
          .map((item) => Destination.fromJson(item as Map<String, dynamic>))
          .toList(),
      deals: dealsList
          .map((item) => Deal.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ========================================
// RIHLA API MODELS FOR REAL FLIGHT DATA
// ========================================
// ========================================
// RIHLA API MODELS FOR REAL FLIGHT DATA
// ========================================
// Update the RihlaFlightData class (lines 225-282) to include lastChecked:

// Update the RihlaFlightData class to better handle API responses
// ========================================
// RIHLA API MODELS FOR REAL FLIGHT DATA
// ========================================
// Update the RihlaFlightData class to include lastChecked:

// Update the RihlaFlightData class to better handle API responses
class RihlaFlightData {
  final String flightNumber;
  final String airline;
  final String departureTime;
  final String arrivalTime;
  final String duration;
  final String aircraft;
  final String origin;
  final String destination;
  final String status;
  final String? lastChecked;
  final String? departureDate; // ADDED: For multi-day trips
  final String? arrivalDate; // ADDED: For multi-day trips

  RihlaFlightData({
    required this.flightNumber,
    required this.airline,
    required this.departureTime,
    required this.arrivalTime,
    required this.duration,
    required this.aircraft,
    required this.origin,
    required this.destination,
    this.status = 'Scheduled',
    this.lastChecked,
    this.departureDate, // ADDED
    this.arrivalDate, // ADDED
  });

  // FIXED: Improved fromJson factory constructor
  // FIXED: Improved fromJson factory constructor
  factory RihlaFlightData.fromJson(Map<String, dynamic> json) {
    try {
      // Extract flight number - handle different field names
      String flightNumber = '';
      if (json['flightCode'] != null &&
          json['flightCode'].toString().isNotEmpty) {
        flightNumber = json['flightCode'].toString();
      } else if (json['flight'] != null &&
          json['flight'].toString().isNotEmpty) {
        flightNumber = json['flight'].toString();
      } else if (json['flightNumber'] != null &&
          json['flightNumber'].toString().isNotEmpty) {
        flightNumber = json['flightNumber'].toString();
      }

      // Extract airline - handle different field names
      String airline = '';
      if (json['airline'] != null && json['airline'].toString().isNotEmpty) {
        airline = json['airline'].toString();
      } else if (json['iataCode'] != null &&
          json['iataCode'].toString().isNotEmpty) {
        airline = json['iataCode'].toString();
      }

      // Extract aircraft - handle different field names
      String aircraft = '';
      if (json['aircraft'] != null && json['aircraft'].toString().isNotEmpty) {
        aircraft = json['aircraft'].toString();
      } else if (json['aircrafttype'] != null &&
          json['aircrafttype'].toString().isNotEmpty) {
        aircraft = json['aircrafttype'].toString();
      }

      // Handle duration - can be string or formatted string
      String durationStr = '';
      if (json['duration_formatted'] != null &&
          json['duration_formatted'].toString().isNotEmpty) {
        durationStr = json['duration_formatted'].toString();
      } else if (json['duration'] != null) {
        final durationValue = json['duration'];
        if (durationValue is int) {
          final hours = durationValue ~/ 60;
          final mins = durationValue % 60;
          durationStr = '${hours}h ${mins}m';
        } else if (durationValue is String) {
          durationStr = durationValue;
        }
      }

      // Extract times
      String departureTime =
          json['departureTime']?.toString() ??
          json['departure_time']?.toString() ??
          json['departure']?.toString() ??
          '--:--';

      String arrivalTime =
          json['arrivalTime']?.toString() ??
          json['arrival_time']?.toString() ??
          json['arrival']?.toString() ??
          '--:--';

      // Extract dates if available (for multi-day trips) - FIXED: Handle null properly
      String? departureDate = json['date']?.toString();
      String? arrivalDate = json['date']
          ?.toString(); // Same as departure for single day

      // Clean up time strings
      departureTime = departureTime.length > 5
          ? departureTime.substring(0, 5)
          : departureTime;
      arrivalTime = arrivalTime.length > 5
          ? arrivalTime.substring(0, 5)
          : arrivalTime;

      return RihlaFlightData(
        flightNumber: flightNumber,
        airline: airline,
        departureTime: departureTime,
        arrivalTime: arrivalTime,
        duration: durationStr,
        aircraft: aircraft,
        origin: json['origin']?.toString() ?? '',
        destination: json['destination']?.toString() ?? '',
        status: json['status']?.toString() ?? 'Scheduled',
        lastChecked: json['lastChecked']?.toString(),
        departureDate: departureDate, // FIXED: Now nullable String?
        arrivalDate: arrivalDate, // FIXED: Now nullable String?
      );
    } catch (e) {
      print('❌ Error parsing flight data: $e');
      print('❌ JSON: $json');

      // Return a minimal valid flight object
      return RihlaFlightData(
        flightNumber: json['flightCode']?.toString() ?? '',
        airline: json['airline']?.toString() ?? 'Unknown',
        departureTime: '--:--',
        arrivalTime: '--:--',
        duration: '',
        aircraft: json['aircraft']?.toString() ?? 'Unknown',
        origin: json['origin']?.toString() ?? '',
        destination: json['destination']?.toString() ?? '',
        status: 'Scheduled',
        departureDate: null, // ADDED
        arrivalDate: null, // ADDED
      );
    }
  }

  DummyFlightResult toDummyFlightResult() {
    return DummyFlightResult(
      airline: airline,
      flightNumber: flightNumber,
      departureTime: departureTime,
      arrivalTime: arrivalTime,
      duration: duration,
      aircraft: aircraft,
      airlineLogoPlaceholder: airline.isNotEmpty
          ? airline
                .substring(0, airline.length < 2 ? airline.length : 2)
                .toUpperCase()
          : '??',
    );
  }

  // Helper method to convert to Flight object
  Flight toFlight({bool isPast = false, int index = 0}) {
    final now = DateTime.now();
    final cityName = mapCities[destination]?.name ?? destination;

    // Generate varied dates using flight number hash
    final flightHash = flightNumber.hashCode.abs();
    final baseOffset = (flightHash % 30) + 1;

    DateTime flightDate;
    if (isPast) {
      // Past: 7-60 days ago
      final daysAgo = (baseOffset * (index + 1)) % 54 + 7;
      flightDate = now.subtract(Duration(days: daysAgo));
    } else {
      // Future: 1-60 days ahead
      final daysAhead = (baseOffset * (index + 1)) % 60 + 1;
      flightDate = now.add(Duration(days: daysAhead));
    }

    return Flight(
      city: cityName,
      route: '$origin → $destination',
      flightNumber: flightNumber,
      status: isPast ? 'Departed' : 'Scheduled',
      airline: airline,
      departureTime: departureTime,
      arrivalTime: arrivalTime,
      duration: duration,
      aircraft: aircraft,
      origin: origin,
      destination: destination,
      flightDate: flightDate,
      lastChecked: lastChecked,
    );
  }
}

// Map Coordinates (Unchanged)
class CityLocation {
  final String name;
  final double lat; // Latitude
  final double lon; // Longitude
  CityLocation({required this.name, required this.lat, required this.lon});
}

class FlightManager {
  static final FlightManager _instance = FlightManager._internal();
  factory FlightManager() => _instance;

  Box<Flight>? _upcomingFlightsBox;
  Box<Flight>? _pastFlightsBox;
  bool _isInitialized = false;

  FlightManager._internal();

  // ============ INITIALIZE HIVE CE ============
  Future<void> init() async {
    if (_isInitialized) return;

    // Open Hive CE boxes
    _upcomingFlightsBox = await Hive.openBox<Flight>('upcoming_flights');
    _pastFlightsBox = await Hive.openBox<Flight>('past_flights');

    // Check and move past flights - ONLY THIS SHOULD CREATE PAST FLIGHTS
    await _checkAndMovePastFlights();

    _isInitialized = true;
    print(
      '✅ Hive CE initialized: ${_upcomingFlightsBox?.length} upcoming, ${_pastFlightsBox?.length} past flights',
    );
  }

  // ============ SIMPLE PAST FLIGHTS LOGIC ============
  Future<void> _checkAndMovePastFlights() async {
    if (_upcomingFlightsBox == null || _pastFlightsBox == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Find and move all flights that are in the past
    for (final flight in _upcomingFlightsBox!.values.toList()) {
      final flightDate = DateTime(
        flight.flightDate.year,
        flight.flightDate.month,
        flight.flightDate.day,
      );

      if (flightDate.isBefore(today)) {
        // Add to past flights
        await _pastFlightsBox!.add(flight);

        // Remove from upcoming flights
        await _removeFlightFromBox(_upcomingFlightsBox!, flight);

        print('➡️ Moved ${flight.flightNumber} to past flights');
      }
    }
  }

  // Helper to remove flight from a box
  Future<void> _removeFlightFromBox(Box<Flight> box, Flight flight) async {
    for (final entry in box.toMap().entries) {
      final boxFlight = entry.value as Flight;
      if (boxFlight.flightNumber == flight.flightNumber &&
          boxFlight.flightDate == flight.flightDate) {
        await box.delete(entry.key);
        return;
      }
    }
  }

  // ============ USER'S UPCOMING FLIGHTS ============

  // Get all upcoming flights
  List<Flight> get upcomingFlights {
    if (!_isInitialized || _upcomingFlightsBox == null) {
      return [];
    }
    return _upcomingFlightsBox!.values.toList();
  }

  // Add a flight to user's upcoming flights
  Future<void> addUserFlight(Flight flight) async {
    if (!_isInitialized || _upcomingFlightsBox == null) {
      await init();
    }

    // Check for duplicates
    final exists = upcomingFlights.any(
      (f) =>
          f.flightNumber == flight.flightNumber &&
          f.flightDate == flight.flightDate,
    );

    if (!exists) {
      await _upcomingFlightsBox!.add(flight);
      print(
        '✅ Added user flight: ${flight.flightNumber} on ${flight.flightDate}',
      );

      // Check if this new flight is already in the past
      await _checkAndMovePastFlights();
    } else {
      print('⚠️ Flight already exists: ${flight.flightNumber}');
    }
  }

  // Remove a flight
  Future<void> removeUserFlight(Flight flight) async {
    if (!_isInitialized || _upcomingFlightsBox == null) return;

    await _removeFlightFromBox(_upcomingFlightsBox!, flight);
    print('✅ Removed flight: ${flight.flightNumber}');
  }

  // Clear all user flights (both upcoming and past)
  Future<void> clearUserFlights() async {
    if (!_isInitialized) return;

    if (_upcomingFlightsBox != null) {
      await _upcomingFlightsBox!.clear();
    }

    if (_pastFlightsBox != null) {
      await _pastFlightsBox!.clear();
    }

    print('✅ Cleared all flights');
  }

  // ============ PAST FLIGHTS ============

  // Get all past flights (ONLY from Hive - no API)
  List<Flight> get pastFlights {
    if (!_isInitialized || _pastFlightsBox == null) {
      return [];
    }
    return _pastFlightsBox!.values.toList();
  }

  // REMOVE the loadPastFlightsFromAPI method completely
  // Past flights should ONLY come from upcoming flights that have passed

  // ============ HELPER METHODS ============

  Flight _createFlightFromRihlaData(
    RihlaFlightData rihlaFlight, {
    bool isPast = false,
    int index = 0,
  }) {
    final cityCode = rihlaFlight.destination;
    final cityName = mapCities[cityCode]?.name ?? cityCode;

    return Flight(
      city: cityName,
      route: '${rihlaFlight.origin} → ${rihlaFlight.destination}',
      flightNumber: rihlaFlight.flightNumber,
      status: 'Scheduled',
      airline: rihlaFlight.airline,
      departureTime: rihlaFlight.departureTime,
      arrivalTime: rihlaFlight.arrivalTime,
      duration: rihlaFlight.duration,
      aircraft: rihlaFlight.aircraft,
      origin: rihlaFlight.origin,
      destination: rihlaFlight.destination,
      flightDate: DateTime.now().add(
        Duration(days: index + 7),
      ), // Simple: 7+ days in future
    );
  }

  // Close boxes when done
  Future<void> close() async {
    if (_upcomingFlightsBox != null && _upcomingFlightsBox!.isOpen) {
      await _upcomingFlightsBox!.close();
    }
    if (_pastFlightsBox != null && _pastFlightsBox!.isOpen) {
      await _pastFlightsBox!.close();
    }
    _isInitialized = false;
  }

  // Check if initialized
  bool get isInitialized => _isInitialized;
}

class LanguagePreferences {
  static final LanguagePreferences _instance = LanguagePreferences._internal();
  factory LanguagePreferences() => _instance;
  LanguagePreferences._internal();

  String currentLanguage = 'English';

  final List<Map<String, String>> supportedLanguages = [
    {'name': 'English', 'code': 'en', 'flag': '🇺🇸'},
    {'name': 'Arabic', 'code': 'ar', 'flag': '🇸🇦'},
    {'name': 'German', 'code': 'de', 'flag': '🇩🇪'},
    {'name': 'French', 'code': 'fr', 'flag': '🇫🇷'},
    {'name': 'Spanish', 'code': 'es', 'flag': '🇪🇸'},
  ];

  void setLanguage(String languageName) {
    currentLanguage = languageName;
  }
}

// Models for the flight offers API response
// Add this method to the FlightOfferSegment class (around line 295-345 in your code)
// Replace the existing FlightOfferSegment class with this updated version:

class FlightOfferSegment {
  final int offerId;
  final String flight;
  final String aircraft;
  final String ticketingUntil;
  final double price;
  final int pricePkr;
  final DateTime date;
  final String origin;
  final String departure; // Time
  final String destination;
  final String arrival; // Time
  final BaggageInfo checkedBag;
  final double? distance;
  final int duration; // in minutes
  final String durationFormatted;
  final double compositeScore;
  final int rank;

  FlightOfferSegment({
    required this.offerId,
    required this.flight,
    required this.aircraft,
    required this.ticketingUntil,
    required this.price,
    required this.pricePkr,
    required this.date,
    required this.origin,
    required this.departure,
    required this.destination,
    required this.arrival,
    required this.checkedBag,
    this.distance,
    required this.duration,
    required this.durationFormatted,
    required this.compositeScore,
    required this.rank,
  });

  factory FlightOfferSegment.fromJson(Map<String, dynamic> json) {
    // Parse date from string like "2025-12-22"
    final dateStr = json['date'] as String;
    final dateParts = dateStr.split('-');
    final date = DateTime(
      int.parse(dateParts[0]),
      int.parse(dateParts[1]),
      int.parse(dateParts[2]),
    );

    // Parse baggage info
    final baggageJson = json['checkedBag'] as Map<String, dynamic>? ?? {};
    final baggageInfo = BaggageInfo(
      weight: baggageJson['weight'] as int? ?? 0,
      weightUnit: baggageJson['weightUnit'] as String? ?? 'KG',
      quantity: baggageJson['quantity'] as int? ?? 0,
    );

    return FlightOfferSegment(
      offerId: json['offer'] as int,
      flight: json['flight'] as String,
      aircraft: (json['aircraft'] as String?) ?? 'Unknown',
      ticketingUntil: json['ticketing_until'] as String,
      price: (json['price'] as num).toDouble(),
      pricePkr: json['price_pkr'] as int,
      date: date,
      origin: json['origin'] as String,
      departure: json['departure'] as String,
      destination: json['destination'] as String,
      arrival: json['arrival'] as String,
      checkedBag: baggageInfo,
      distance: (json['distance'] as num?)?.toDouble(),
      duration: json['duration'] as int,
      durationFormatted: json['duration_formatted'] as String,
      compositeScore: (json['score_composite'] as num).toDouble(),
      rank: json['rank'] as int,
    );
  }

  // NEW: Add copyWith method for immutable updates
  FlightOfferSegment copyWith({
    int? offerId,
    String? flight,
    String? aircraft,
    String? ticketingUntil,
    double? price,
    int? pricePkr,
    DateTime? date,
    String? origin,
    String? departure,
    String? destination,
    String? arrival,
    BaggageInfo? checkedBag,
    double? distance,
    int? duration,
    String? durationFormatted,
    double? compositeScore,
    int? rank,
  }) {
    return FlightOfferSegment(
      offerId: offerId ?? this.offerId,
      flight: flight ?? this.flight,
      aircraft: aircraft ?? this.aircraft,
      ticketingUntil: ticketingUntil ?? this.ticketingUntil,
      price: price ?? this.price,
      pricePkr: pricePkr ?? this.pricePkr,
      date: date ?? this.date,
      origin: origin ?? this.origin,
      departure: departure ?? this.departure,
      destination: destination ?? this.destination,
      arrival: arrival ?? this.arrival,
      checkedBag: checkedBag ?? this.checkedBag,
      distance: distance ?? this.distance,
      duration: duration ?? this.duration,
      durationFormatted: durationFormatted ?? this.durationFormatted,
      compositeScore: compositeScore ?? this.compositeScore,
      rank: rank ?? this.rank,
    );
  }

  // Convert to RihlaFlightData for compatibility with existing UI
  RihlaFlightData toRihlaFlightData() {
    // Extract airline code from flight number (e.g., "PK203" -> "PK")
    final airline = flight.length >= 2 ? flight.substring(0, 2) : '';

    return RihlaFlightData(
      flightNumber: flight,
      airline: airline,
      departureTime: departure,
      arrivalTime: arrival,
      duration: durationFormatted,
      aircraft: aircraft,
      origin: origin,
      destination: destination,
      status: 'Scheduled',
    );
  }
}

class BaggageInfo {
  final int weight;
  final String weightUnit;
  final int quantity;

  BaggageInfo({
    required this.weight,
    required this.weightUnit,
    required this.quantity,
  });

  String get displayText {
    if (quantity > 0) return '$quantity bag${quantity > 1 ? 's' : ''}';
    if (weight > 0) return '$weight $weightUnit';
    return 'No baggage';
  }
}

// Update the FlightOffer class (around line 335-370) to include total trip duration

class FlightOffer {
  final int id;
  final List<FlightOfferSegment> segments;
  final double totalPrice;
  final int totalPricePkr;
  final int rank;
  final double compositeScore;
  final String totalTripDuration; // NEW: Total trip duration including layovers
  final String?
  totalDisplayDuration; // ADDED: Formatted total duration with days

  FlightOffer({
    required this.id,
    required this.segments,
    required this.totalPrice,
    required this.totalPricePkr,
    required this.rank,
    required this.compositeScore,
    required this.totalTripDuration, // NEW
    this.totalDisplayDuration, // ADDED
  });

  bool get isMultiLeg => segments.length > 1;

  String get displayRoute {
    if (segments.isEmpty) return '';
    if (segments.length == 1) {
      return '${segments.first.origin} → ${segments.first.destination}';
    }
    final first = segments.first;
    final last = segments.last;
    return '${first.origin} → ... → ${last.destination} (${segments.length - 1} stop${segments.length > 2 ? 's' : ''})';
  }

  // UPDATED: Get correct display duration for both direct and connecting flights
  String get displayDuration {
    // Use pre-calculated total display duration if available (for connecting flights)
    if (totalDisplayDuration != null && totalDisplayDuration!.isNotEmpty) {
      return totalDisplayDuration!;
    }

    // Use totalTripDuration if available
    if (totalTripDuration.isNotEmpty) {
      return totalTripDuration;
    }

    // Fallback for single segment flights
    if (segments.isEmpty) return '';
    if (segments.length == 1) {
      return segments.first.durationFormatted;
    }

    // Calculate from segments as fallback
    final totalMinutes = segments.fold(
      0,
      (sum, segment) => sum + segment.duration,
    );
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;

    // Format with days if more than 24 hours
    if (hours >= 24) {
      final days = hours ~/ 24;
      final remainingHours = hours % 24;
      return '${days}d ${remainingHours}h ${minutes}m';
    }

    return '${hours}h ${minutes}m';
  }

  // UPDATED: Get duration for display in FlightResultCard
  String get displayDurationForCard {
    if (isMultiLeg) {
      // For connecting flights, show "Total: Xd Xh Xm" or "Total: Xh Xm"
      return 'Total: $displayDuration';
    }
    return displayDuration;
  }

  // Add a method to format times with AM/PM
  String formatTimeWithAmPm(String time24) {
    try {
      final parts = time24.split(':');
      if (parts.length != 2) return time24;

      int hour = int.parse(parts[0]);
      int minute = int.parse(parts[1]);

      String period = hour >= 12 ? 'PM' : 'AM';
      hour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);

      return '${hour}:${minute.toString().padLeft(2, '0')} $period';
    } catch (e) {
      return time24;
    }
  }

  // Get first segment for compatibility
  FlightOfferSegment get firstSegment => segments.first;
}

// --- TRAVEL PREFERENCES ---

class TravelPreferences {
  static final TravelPreferences _instance = TravelPreferences._internal();
  factory TravelPreferences() => _instance;
  TravelPreferences._internal() {
    _loadPreferences();
  }

  String preferredAirport = 'LHE';
  Set<String> preferredRegions = {'Middle East', 'South Asia'};
  String preferredCurrency = 'USD';

  final Map<String, String> regionDisplayNames = {
    'Middle East': 'Middle East',
    'South Asia': 'South Asia',
    'East Asia': 'East Asia',
    'Europe': 'Europe',
    'North America': 'North America',
    'South America': 'South America',
    'Oceania': 'Oceania',
    'East Africa': 'East Africa',
    'West Africa': 'West Africa',
    'Central Africa': 'Central Africa',
    'Southern Africa': 'Southern Africa',
    'Central Asia': 'Central Asia',
    'North Africa': 'North Africa',
  };

  final List<String> supportedCurrencies = [
    'USD',
    'EUR',
    'GBP',
    'PKR',
    'AED',
    'SAR',
    'INR',
    'CNY',
    'JPY',
  ];

  // Load preferences from SharedPreferences
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    preferredAirport = prefs.getString('preferredAirport') ?? 'LHE';
    preferredCurrency = prefs.getString('preferredCurrency') ?? 'USD';

    final regionsJson = prefs.getStringList('preferredRegions');
    if (regionsJson != null && regionsJson.isNotEmpty) {
      preferredRegions = regionsJson.toSet();
    }
  }

  // Save preferences
  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('preferredAirport', preferredAirport);
    await prefs.setString('preferredCurrency', preferredCurrency);
    await prefs.setStringList('preferredRegions', preferredRegions.toList());
  }

  void toggleRegion(String region) {
    if (preferredRegions.contains(region)) {
      preferredRegions.remove(region);
    } else {
      preferredRegions.add(region);
    }
    _savePreferences();
  }

  Future<void> setPreferredAirport(String airportCode) async {
    preferredAirport = airportCode;
    await _savePreferences();
  }

  Future<void> setCurrency(String currency) async {
    preferredCurrency = currency;
    await _savePreferences();
  }

  Future<void> resetToDefault() async {
    preferredAirport = 'LHE';
    preferredRegions = {'Middle East', 'South Asia'};
    preferredCurrency = 'USD';
    await _savePreferences();
  }
}

// --- 3. API SERVICE & DUMMY DATA ---

// Update the RihlaApiService class
class RihlaApiService {
  // CORS Proxy Configuration
  static const bool _useProxy = true; // Set to false for mobile/production
  static const String _corsProxy = 'https://corsproxy.io/?';
  static const String baseURL = 'https://api.rihla.cc/v1';

  // API Key for authentication
  static const String _apiKey = 'O2vfZMng8cHqQWdmhm-yyS4q_yORIeeALYqu9-744uY';

  // Helper to build URL with CORS proxy for web
  static String _buildUrl(String endpoint) {
    final fullUrl = '$baseURL$endpoint';
    // Use proxy only when running on web and _useProxy is true
    if (_useProxy && kIsWeb) {
      return '$_corsProxy${Uri.encodeFull(fullUrl)}';
    }
    return fullUrl;
  }

  static Future<List<FlightOffer>> searchFlightOffers({
    required String origin,
    required String destination,
    required DateTime departureDate,
    String currency = 'USD',
    double? maxBudget,
  }) async {
    try {
      // Format date to YYYY-MM-DD
      final String formattedDate =
          "${departureDate.year}-${departureDate.month.toString().padLeft(2, '0')}-${departureDate.day.toString().padLeft(2, '0')}";

      // Build the URL for the offers endpoint
      String url = _buildUrl(
        '/offers/search?origin=$origin&destination=$destination&departure_date=$formattedDate&currency=$currency',
      );

      if (maxBudget != null) {
        url += '&budget=${maxBudget.toInt()}';
      }

      print('═══════════════════════════════════════');
      print('💰 API Request (Offers): $url');

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));

      print('📡 Status Code: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ Offers API Response successful');

        if (data['has_results'] == false || data['results'] == null) {
          print('⚠️ No offers found for the selected date');
          return [];
        }

        final List<dynamic> offersList = data['results'] as List<dynamic>;
        print('✈️ Found ${offersList.length} offer segments');

        // Parse all segments first
        final List<FlightOfferSegment> allSegments = [];
        for (var offerData in offersList) {
          try {
            final segment = FlightOfferSegment.fromJson(
              offerData as Map<String, dynamic>,
            );
            allSegments.add(segment);
          } catch (e) {
            print('❌ Error parsing offer segment: $e');
          }
        }

        // Group segments by offerId
        final Map<int, List<FlightOfferSegment>> groupedOffers = {};
        for (final segment in allSegments) {
          groupedOffers.putIfAbsent(segment.offerId, () => []).add(segment);
        }

        print('📊 Grouped into ${groupedOffers.length} complete offers');

        // Create complete FlightOffer objects from grouped segments
        final List<FlightOffer> completeOffers = [];
        groupedOffers.forEach((offerId, segments) {
          // Sort segments by date and time to maintain itinerary order
          segments.sort((a, b) {
            final dateCompare = a.date.compareTo(b.date);
            if (dateCompare != 0) return dateCompare;
            return _timeToMinutes(
              a.departure,
            ).compareTo(_timeToMinutes(b.departure));
          });

          // Calculate total price as sum of all segment prices
          // (Note: In your API response, all segments have the same price for the offer)
          final totalPrice = segments.first.price;
          final totalPricePkr = segments.first.pricePkr;
          final rank = segments.first.rank;
          final compositeScore = segments.first.compositeScore;

          // Calculate total trip duration including layovers
          String totalDisplayDuration = '';
          try {
            // Parse first departure
            final firstSegment = segments.first;
            final lastSegment = segments.last;

            final firstDateStr =
                "${firstSegment.date.year.toString().padLeft(4, '0')}-${firstSegment.date.month.toString().padLeft(2, '0')}-${firstSegment.date.day.toString().padLeft(2, '0')}";
            DateTime firstDepartureDateTime = DateTime.parse(
              '$firstDateStr ${firstSegment.departure}:00',
            );

            // Parse last arrival
            final lastDateStr =
                "${lastSegment.date.year.toString().padLeft(4, '0')}-${lastSegment.date.month.toString().padLeft(2, '0')}-${lastSegment.date.day.toString().padLeft(2, '0')}";
            DateTime lastArrivalDateTime = DateTime.parse(
              '$lastDateStr ${lastSegment.arrival}:00',
            );

            // If arrival time is earlier than departure time, assume next day
            if (lastArrivalDateTime.isBefore(firstDepartureDateTime)) {
              lastArrivalDateTime = lastArrivalDateTime.add(
                const Duration(days: 1),
              );
            }

            // Calculate total duration in minutes
            final totalMinutes = lastArrivalDateTime
                .difference(firstDepartureDateTime)
                .inMinutes;

            // Format: days, hours, minutes
            final days = totalMinutes ~/ (24 * 60);
            final hours = (totalMinutes % (24 * 60)) ~/ 60;
            final minutes = totalMinutes % 60;

            if (days > 0) {
              totalDisplayDuration = '${days}d ${hours}h ${minutes}m';
            } else {
              totalDisplayDuration = '${hours}h ${minutes}m';
            }
          } catch (e) {
            print('⚠️ Error calculating total duration: $e');
            // Fallback: sum of segment durations
            final totalMinutes = segments.fold(
              0,
              (sum, segment) => sum + segment.duration,
            );
            final hours = totalMinutes ~/ 60;
            final minutes = totalMinutes % 60;
            totalDisplayDuration = '${hours}h ${minutes}m';
          }

          completeOffers.add(
            FlightOffer(
              id: offerId,
              segments: segments,
              totalPrice: totalPrice,
              totalPricePkr: totalPricePkr,
              rank: rank,
              compositeScore: compositeScore,
              totalTripDuration: totalDisplayDuration,
              totalDisplayDuration: totalDisplayDuration,
            ),
          );
        });

        // Sort offers by rank (best offers first)
        completeOffers.sort((a, b) => a.rank.compareTo(b.rank));

        print('✅ Successfully parsed ${completeOffers.length} complete offers');
        return completeOffers;
      } else {
        print('❌ Offers API Error: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e, stackTrace) {
      print('❌ API Error (flight offers): $e');
      print('Stack trace: $stackTrace');
      return [];
    }
  }

  // Helper to convert time string "HH:MM" to minutes for sorting
  static int _timeToMinutes(String time) {
    try {
      final parts = time.split(':');
      if (parts.length == 2) {
        return int.parse(parts[0]) * 60 + int.parse(parts[1]);
      }
    } catch (e) {
      print('Error parsing time: $time');
    }
    return 0;
  }

  // FIXED: Add proper headers with API key
  static Map<String, String> get headers {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'x-api-key': _apiKey,
    };
  }

  // FIXED: Improved searchFlights method
  static Future<List<RihlaFlightData>> searchFlights({
    required String origin,
    required String destination,
    String? date,
  }) async {
    try {
      // Updated endpoint format based on your API documentation
      String url = _buildUrl(
        '/flights?origin=$origin&destination=$destination',
      );
      print('═══════════════════════════════════════');
      print('🌐 API Request: $url');
      print('Headers: ${headers.keys}');

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));

      print('📡 Status Code: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ API Response successful');

        // Check if results exist
        if (data['has_results'] == false || data['results'] == null) {
          print('⚠️ No results found in API response');
          return [];
        }

        final List<dynamic> flightsList = data['results'] as List<dynamic>;
        print('✈️ Found ${flightsList.length} flights');

        // Parse flights
        final List<RihlaFlightData> parsedFlights = [];
        for (var flightData in flightsList) {
          try {
            final flight = RihlaFlightData.fromJson(
              flightData as Map<String, dynamic>,
            );
            parsedFlights.add(flight);
          } catch (e) {
            print('❌ Error parsing flight: $e');
          }
        }

        print('✅ Successfully parsed ${parsedFlights.length} flights');
        return parsedFlights;
      } else {
        print('❌ API Error: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e, stackTrace) {
      print('❌ API Error (search flights): $e');
      print('Stack trace: $stackTrace');
      return [];
    }
  }

  // FIXED: Improved fetchFlightsByAirport method
  static Future<List<RihlaFlightData>> fetchFlightsByAirport(
    String airport,
  ) async {
    try {
      String url = _buildUrl('/flights/byAirport?airport=$airport');
      print('🔍 Fetching flights for airport: $airport');

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['has_results'] == false || data['results'] == null) {
          print('⚠️ No flights found for airport $airport');
          return [];
        }

        final List<dynamic> flightsList = data['results'] as List<dynamic>;
        print('✅ Found ${flightsList.length} flights for airport $airport');

        return flightsList
            .map(
              (item) => RihlaFlightData.fromJson(item as Map<String, dynamic>),
            )
            .where(
              (flight) => flight.flightNumber.isNotEmpty,
            ) // Filter valid flights
            .toList();
      } else {
        print('❌ API Error: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('❌ API Error (flights by airport): $e');
      return [];
    }
  }

  // FIXED: Improved fetchFlightByCode method
  static Future<RihlaFlightData?> fetchFlightByCode(String flightCode) async {
    try {
      String url = _buildUrl('/flights/byCode/$flightCode');
      print('🔍 Fetching flight by code: $flightCode');

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['has_results'] == false || data['results'] == null) {
          print('⚠️ No flight found with code $flightCode');
          return null;
        }

        final List<dynamic> results = data['results'] as List<dynamic>;
        if (results.isEmpty) {
          return null;
        }

        return RihlaFlightData.fromJson(results[0] as Map<String, dynamic>);
      } else {
        print('⚠️ API returned status ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ API Error (flight by code): $e');
      return null;
    }
  }

  // FIXED: Improved fetchRecommendations with proper error handling
  static Future<RecommendationResponse> fetchRecommendations() async {
    try {
      String url = _buildUrl('/home/recommendations');
      print('🔍 Fetching home recommendations');

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        // Validate response structure
        if (!data.containsKey('destinations') || !data.containsKey('deals')) {
          print('⚠️ Invalid recommendations response structure');
          return RecommendationResponse(destinations: [], deals: []);
        }

        print('✅ Recommendations fetched successfully');
        return RecommendationResponse.fromJson(data);
      } else {
        print('⚠️ Recommendations API returned status ${response.statusCode}');
        return RecommendationResponse(destinations: [], deals: []);
      }
    } catch (e) {
      print('❌ API Error (recommendations): $e');
      return RecommendationResponse(destinations: [], deals: []);
    }
  }
}
// Convert worldAirports to Airport objects
// ========================================
// AIRPORT DATA INITIALIZATION
// ========================================

// Global variables (will be populated after loading JSON)
List<Airport> dummyAirports = [];
Map<String, CityLocation> mapCities = {};

// ✅ Initialize airport data AFTER loading from JSON
// Update the initializeAirportData function:

void initializeAirportData() {
  if (worldAirports.isEmpty) {
    print('⚠️ Warning: worldAirports is empty!');
    return;
  }

  // Filter out invalid airport codes
  final validAirports = worldAirports.where((airport) {
    // Valid IATA codes are 3 uppercase letters, no numbers
    final isValidCode =
        airport.code.length == 3 &&
        airport.code.toUpperCase() == airport.code &&
        !RegExp(r'[0-9]').hasMatch(airport.code);

    // Also filter out known problematic codes
    final isNotProblematic = ![
      'M6X',
      'UGC',
      'CRZ',
      'KDU',
      'BNP',
      'LIK',
      'KHY',
    ].contains(airport.code);

    return isValidCode && isNotProblematic;
  }).toList();

  // Convert to Airport objects for UI
  dummyAirports = validAirports
      .map(
        (airportData) => Airport(
          name: airportData.name,
          code: airportData.code,
          city: airportData.city,
          country: airportData.country,
        ),
      )
      .toList();

  // Create city location map for map display
  mapCities = Map.fromEntries(
    validAirports.map(
      (airport) => MapEntry(
        airport.code,
        CityLocation(name: airport.city, lat: airport.lat, lon: airport.lon),
      ),
    ),
  );

  print('✅ Initialized ${dummyAirports.length} valid airports');
  print(
    '✅ Filtered out ${worldAirports.length - dummyAirports.length} invalid airports',
  );
  print('✅ Initialized ${mapCities.length} city locations');
}

// DUMMY FLIGHT DATA FOR RESULTS SCREEN
class DummyFlightResult {
  final String airline;
  final String flightNumber;
  final String departureTime;
  final String arrivalTime;
  final String duration;
  final String aircraft;
  final String airlineLogoPlaceholder;

  DummyFlightResult({
    required this.airline,
    required this.flightNumber,
    required this.departureTime,
    required this.arrivalTime,
    required this.duration,
    required this.aircraft,
    required this.airlineLogoPlaceholder,
  });
}

// Updated main() function with proper error handling

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive CE
  Hive.initFlutter(); // No await needed for hive_ce

  // Register adapters
  Hive.registerAdapter(FlightAdapter());

  try {
    // Initialize localization
    await EasyLocalization.ensureInitialized();

    print('🚀 Starting Rihla App...');

    // Load airports data
    await loadAirportsFromJson();
    initializeAirportData();

    // Load airline data
    await AirlineService.loadAirlines();

    print('✅ App initialization complete!');

    runApp(
      EasyLocalization(
        supportedLocales: const [
          Locale('en'),
          Locale('ar'),
          Locale('de'),
          Locale('fr'),
          Locale('es'),
        ],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        saveLocale: true,
        child: const RihlaApp(),
      ),
    );
  } catch (error, stackTrace) {
    print('❌ Failed to initialize app: $error');
    print('Stack trace: $stackTrace');

    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 20),
                const Text(
                  'App Initialization Failed',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'Error: ${error.toString()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RihlaApp extends StatelessWidget {
  const RihlaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'app_title'.tr(),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0C1324),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0C1324),
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.white),
        ),
        textTheme: TextTheme(
          bodyMedium: TextStyle(
            color: Colors.white,
            fontFamily: context.locale.languageCode == 'ar'
                ? 'NotoKufiArabic'
                : null,
          ),
          headlineLarge: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 28,
          ),
          titleLarge: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFDC64C),
          brightness: Brightness.dark,
          primary: const Color(0xFFFDC64C),
          background: const Color(0xFF0C1324),
        ),
        useMaterial3: true,
      ),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaleFactor: 1.0),
          child: child!,
        );
      },
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  // Global key to access MainScreen state from anywhere
  static final GlobalKey<_MainScreenState> mainScreenKey =
      GlobalKey<_MainScreenState>();

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const HomeScreenContent(),
    const PlaceholderScreen(title: 'Book Flights'),
    const TripsScreen(),
    const PlaceholderScreen(title: 'AI Planner'),
    const PlaceholderScreen(title: 'Profile'),
    const MoreScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  // Navigate to a specific tab index (called from TripsScreen back button)
  void navigateToTab(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  // In the MainScreen build method, update the app bar:

  PreferredSizeWidget _buildAppBar() {
    if (_currentIndex == 0) {
      return AppBar(
        backgroundColor: const Color(0xFF0C1324),
        elevation: 0,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.waves, color: Color(0xFFFDC64C), size: 32),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Rihla',
                  style: TextStyle(
                    color: Color(0xFFFDC64C),
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Beyond the Journey',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 10,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFFFDC64C).withOpacity(0.2),
              child: const Icon(
                Icons.person,
                color: Color(0xFFFDC64C),
                size: 20,
              ),
            ),
          ),
        ],
        centerTitle: true,
      );
    }
    return AppBar(
      backgroundColor: const Color(0xFF0C1324),
      elevation: 0,
      title: Text(
        _screens[_currentIndex] is PlaceholderScreen
            ? (_screens[_currentIndex] as PlaceholderScreen).title
            : 'Rihla',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      centerTitle: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    bool useAppBar = _currentIndex != 2;

    return Scaffold(
      appBar: useAppBar ? _buildAppBar() : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                maxWidth: constraints.maxWidth,
                minHeight: constraints.maxHeight,
                maxHeight: constraints.maxHeight,
              ),
              child: _screens[_currentIndex],
            ),
          );
        },
      ),
      bottomNavigationBar: MediaQuery.of(context).viewInsets.bottom > 0
          ? null // Hide bottom nav when keyboard is open
          : RihlaBottomNavBar(
              currentIndex: _currentIndex,
              onTap: _onItemTapped,
            ),
    );
  }
}

// --- 5. MORE SCREEN & TRAVEL PREFERENCES ---

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF161F34),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: const Color(0xFFFDC64C), size: 22),
          ),
          title: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                )
              : null,
          trailing: const Icon(
            Icons.arrow_forward_ios,
            size: 16,
            color: Colors.white30,
          ),
          onTap: onTap,
        ),
        Divider(height: 1, color: Colors.white.withOpacity(0.05), indent: 70),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        title: const Text(
          'More',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF0C1324),
        centerTitle: true,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          _buildMenuItem(
            icon: Icons.settings_outlined,
            title: 'Travel Preferences',
            subtitle: 'Airports, Regions, Currency',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TravelPreferencesScreen(),
                  fullscreenDialog: true,
                ),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.language,
            title: 'Language',
            subtitle: LanguagePreferences().currentLanguage,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LanguageScreen()),
              ).then((_) => setState(() {}));
            },
          ),
          _buildMenuItem(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationSettingsScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              "SUPPORT & LEGAL",
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
          _buildMenuItem(
            icon: Icons.security,
            title: 'Privacy & Security',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const PrivacySecurityScreen(),
                ),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.help_outline,
            title: 'Help & Support',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const HelpSupportScreen(),
                ),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.info_outline,
            title: 'About Rihla',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AboutScreen()),
              );
            },
          ),
          // Add this to MoreScreen
          // In the MoreScreen build method
          _buildMenuItem(
            icon: Icons.delete_sweep,
            title: 'Clear All Flights',
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear All Flights'),
                  content: const Text(
                    'This will remove all your saved flights. Continue?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await FlightManager().clearUserFlights();
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('All flights cleared'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                      child: const Text(
                        'Clear All',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 30),
          Center(
            child: Text(
              "Version 1.0.0 (Build 102)",
              style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TravelPreferencesScreen extends StatefulWidget {
  const TravelPreferencesScreen({super.key});

  @override
  State<TravelPreferencesScreen> createState() =>
      _TravelPreferencesScreenState();
}

class _TravelPreferencesScreenState extends State<TravelPreferencesScreen> {
  final TravelPreferences prefs = TravelPreferences();

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    await prefs._loadPreferences();
    if (mounted) setState(() {});
  }

  void _selectAirport() async {
    final selectedAirport = await Navigator.push<Airport>(
      context,
      MaterialPageRoute(
        builder: (context) => const AirportSelectionScreen(),
        fullscreenDialog: true,
      ),
    );

    if (selectedAirport != null) {
      await prefs.setPreferredAirport(selectedAirport.code);
      if (mounted) setState(() {});
      _showSnackBar('Airport updated to ${selectedAirport.code}');
    }
  }

  void _selectCurrency() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select Currency',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 20),
              ...prefs.supportedCurrencies.map((currency) {
                final isSelected = prefs.preferredCurrency == currency;
                return ListTile(
                  title: Text(currency),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle, color: Color(0xFF1E90FF))
                      : null,
                  onTap: () async {
                    await prefs.setCurrency(currency);
                    setState(() {});
                    Navigator.pop(context);
                    _showSnackBar('Currency set to $currency');
                  },
                );
              }).toList(),
            ],
          ),
        );
      },
    );
  }

  Future<void> _resetToDefault() async {
    await prefs.resetToDefault();
    if (mounted) setState(() {});
    _showSnackBar('Preferences reset to default');
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildRegionChip(String region) {
    final bool isSelected = prefs.preferredRegions.contains(region);
    final displayText = prefs.regionDisplayNames[region] ?? region;

    return FilterChip(
      label: Text(displayText),
      selected: isSelected,
      onSelected: (bool value) {
        setState(() {
          prefs.toggleRegion(region);
        });
      },
      selectedColor: const Color(0xFF1E90FF).withOpacity(0.15),
      checkmarkColor: const Color(0xFF1E90FF),
      labelStyle: TextStyle(
        color: isSelected ? const Color(0xFF1E90FF) : Colors.black87,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(
        color: isSelected ? const Color(0xFF1E90FF) : Colors.grey.shade300,
        width: isSelected ? 2 : 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Color(0xFF1E90FF)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Travel Preferences',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),

            // Preferred Airport
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PREFERRED AIRPORT',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 15),
                  InkWell(
                    onTap: _selectAirport,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E90FF).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                prefs.preferredAirport,
                                style: const TextStyle(
                                  color: Color(0xFF1E90FF),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.flight_takeoff,
                                color: Color(0xFF1E90FF),
                                size: 20,
                              ),
                            ],
                          ),
                          const Text(
                            'tap to change',
                            style: TextStyle(
                              color: Color(0xFF1E90FF),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your default departure airport for searches',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Currency
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CURRENCY',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 15),
                  InkWell(
                    onTap: _selectCurrency,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E90FF).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                prefs.preferredCurrency,
                                style: const TextStyle(
                                  color: Color(0xFF1E90FF),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.attach_money,
                                color: Color(0xFF1E90FF),
                                size: 20,
                              ),
                            ],
                          ),
                          const Text(
                            'tap to change',
                            style: TextStyle(
                              color: Color(0xFF1E90FF),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Prices will be shown in this currency',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Preferred Regions
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PREFERRED REGIONS',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: prefs.regionDisplayNames.keys
                        .map((region) => _buildRegionChip(region))
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Select regions for personalized recommendations',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            // Reset Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton(
                  onPressed: _resetToDefault,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Reset to Default',
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// --- 6. NAVIGATION, WIDGETS, AND SCREENS ---

class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.white70,
        ),
      ),
    );
  }
}

class RihlaBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int>? onTap;

  const RihlaBottomNavBar({super.key, this.currentIndex = 0, this.onTap});

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      backgroundColor: const Color(0xFF161F34),
      type: BottomNavigationBarType.fixed,
      selectedItemColor: const Color(0xFFFDC64C),
      unselectedItemColor: Colors.white70,
      showUnselectedLabels: true,
      selectedFontSize: 12,
      unselectedFontSize: 12,
      currentIndex: currentIndex,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
        BottomNavigationBarItem(
          icon: Icon(Icons.flight_takeoff),
          label: 'Book',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.calendar_month),
          label: 'Trips',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble_outline),
          label: 'AI Planner',
        ),
        BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: 'More'),
      ],
      onTap: onTap,
    );
  }
}

// --- HOME SCREEN CONTENT ---

// --- HOME SCREEN CONTENT ---
// --- HOME SCREEN CONTENT (FULLY UPDATED) ---
// --- HOME SCREEN CONTENT (FULLY UPDATED) ---
// Replace the entire HomeScreenContent class with this new version:

// Replace the entire HomeScreenContent class with this polished version:

// Replace the entire HomeScreenContent class with this improved version
class HomeScreenContent extends StatefulWidget {
  const HomeScreenContent({super.key});

  @override
  State<HomeScreenContent> createState() => _HomeScreenContentState();
}

class _HomeScreenContentState extends State<HomeScreenContent>
    with ResponsiveMixin {
  late Future<RecommendationResponse> recommendations;
  final PageController pageController = PageController();
  int currentPage = 0;
  Timer? autoSlideTimer;
  final TextEditingController searchController = TextEditingController();
  bool isSearching = false;
  List<RihlaFlightData> searchResults = [];
  List<Airport> searchSuggestions = [];
  Timer? searchDebounceTimer;
  final FocusNode _searchFocusNode = FocusNode();
  bool _showSearchOverlay = false;
  String _currentSearchType = '';

  @override
  void initState() {
    super.initState();
    recommendations = _fetchRecommendationsWithRetry();
    startAutoSlide();

    // ========== UPDATE THIS PART ==========
    _searchFocusNode.addListener(() {
      // Show overlay when focused
      if (_searchFocusNode.hasFocus) {
        setState(() {
          _showSearchOverlay = true;
        });
      }
    });
    // ========== END OF UPDATE ==========
  }

  Future<RecommendationResponse> _fetchRecommendationsWithRetry() async {
    int retries = 3;
    for (int i = 0; i < retries; i++) {
      try {
        final response = await RihlaApiService.fetchRecommendations();
        if (response.destinations.isNotEmpty || response.deals.isNotEmpty) {
          return response;
        }
        await Future.delayed(Duration(seconds: 1 * (i + 1)));
      } catch (e) {
        print('⚠️ Recommendation fetch attempt ${i + 1} failed: $e');
        if (i == retries - 1) rethrow;
      }
    }
    return RecommendationResponse(destinations: [], deals: []);
  }

  void startAutoSlide() {
    autoSlideTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (pageController.hasClients && currentPage < 7) {
        final nextPage = (currentPage + 1) % 8;
        pageController.animateToPage(
          nextPage,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void dispose() {
    pageController.dispose();
    autoSlideTimer?.cancel();
    searchController.dispose();
    searchDebounceTimer?.cancel();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // ========== REPLACE THE EXISTING performSearch() METHOD WITH THIS ==========
  void performSearch(String query) async {
    if (query.isEmpty) {
      setState(() {
        isSearching = false;
        searchResults.clear();
        _showSearchOverlay = false;
      });
      return;
    }

    // Cancel previous debounce timer
    searchDebounceTimer?.cancel();

    // Update UI immediately
    setState(() {
      isSearching = true;
      searchResults.clear();
      _showSearchOverlay = true;
    });

    searchDebounceTimer = Timer(const Duration(milliseconds: 500), () async {
      await _executeComprehensiveSearch(query);
    });
  }

  Future<void> _executeComprehensiveSearch(String query) async {
    try {
      final cleanQuery = query.trim().toUpperCase();
      List<RihlaFlightData> allResults = [];

      // 1. Check for direct flight number match (API: /flights/byCode/{code})
      if (RegExp(r'^[A-Z]{2}\d+$').hasMatch(cleanQuery)) {
        final flight = await RihlaApiService.fetchFlightByCode(cleanQuery);
        if (flight != null) allResults.add(flight);
      }

      // 2. Check for route pattern (API: /flights?origin=X&destination=Y)
      final routePatterns = [
        RegExp(r'^([A-Z]{3})\s+([A-Z]{3})$'), // "LHE DXB"
        RegExp(r'^([A-Z]{3})-([A-Z]{3})$'), // "LHE-DXB"
        RegExp(r'^([A-Z]{3})TO([A-Z]{3})$', caseSensitive: false), // "LHEtoDXB"
      ];

      for (final pattern in routePatterns) {
        final match = pattern.firstMatch(cleanQuery);
        if (match != null && match.groupCount >= 2) {
          final origin = match.group(1)!;
          final destination = match.group(2)!;
          final flights = await RihlaApiService.searchFlights(
            origin: origin,
            destination: destination,
          );
          allResults.addAll(flights);
          break;
        }
      }

      // 3. Check for airport code (API: /flights/byAirport?airport=XXX)
      if (cleanQuery.length == 3 && allResults.isEmpty) {
        final flights = await RihlaApiService.fetchFlightsByAirport(cleanQuery);
        allResults.addAll(flights.take(10)); // Limit to avoid overwhelming
      }

      // 4. City/Airport name search (from your dummyAirports)
      if (allResults.isEmpty) {
        final matchingAirports = dummyAirports.where((airport) {
          final cityMatch = airport.city.toLowerCase().contains(
            query.toLowerCase(),
          );
          final nameMatch = airport.name.toLowerCase().contains(
            query.toLowerCase(),
          );
          return cityMatch || nameMatch;
        }).toList();

        if (matchingAirports.isNotEmpty) {
          // Try the first matching airport
          final airportCode = matchingAirports.first.code;
          final flights = await RihlaApiService.fetchFlightsByAirport(
            airportCode,
          );
          allResults.addAll(flights.take(8));
        }
      }

      // 5. Airline search (from your AirlineService)
      if (allResults.isEmpty) {
        final airline = AirlineService.getAirlineByCode(cleanQuery);
        if (airline != null) {
          // Show popular flights for this airline
          final popularAirports = ['DXB', 'LHR', 'JFK', 'SIN', 'HKG'];
          for (final airport in popularAirports) {
            final flights = await RihlaApiService.fetchFlightsByAirport(
              airport,
            );
            final airlineFlights = flights
                .where(
                  (f) =>
                      f.airline == cleanQuery ||
                      AirlineService.getAirlineName(
                        f.airline,
                      ).toLowerCase().contains(query.toLowerCase()),
                )
                .take(2);
            allResults.addAll(airlineFlights);
          }
        }
      }

      // Remove duplicates
      final uniqueResults = <String, RihlaFlightData>{};
      for (final flight in allResults) {
        final key =
            '${flight.flightNumber}|${flight.origin}|${flight.destination}';
        uniqueResults[key] = flight;
      }

      setState(() {
        searchResults = uniqueResults.values.toList();
        isSearching = false;
      });
    } catch (e) {
      print('❌ Comprehensive search error: $e');
      setState(() {
        searchResults.clear();
        isSearching = false;
      });
    }
  }

  Future<void> _executeSearch(String query) async {
    if (query.isEmpty) return;

    setState(() {
      isSearching = true;
      searchResults.clear();
    });

    try {
      final cleanQuery = query.trim().toUpperCase();
      List<RihlaFlightData> foundFlights = [];

      // 1. Check for flight number (e.g., QR740)
      if (RegExp(r'^[A-Za-z]{2}\d+$').hasMatch(cleanQuery)) {
        print('🔍 Searching flight by code: $cleanQuery');
        final flight = await RihlaApiService.fetchFlightByCode(cleanQuery);
        if (flight != null) {
          foundFlights.add(flight);
        }
      }
      // 2. Check for route (e.g., LHE DXB or LHE-DXB)
      else if (RegExp(r'^[A-Za-z]{3}\s+[A-Za-z]{3}$').hasMatch(cleanQuery) ||
          RegExp(r'^[A-Za-z]{3}-[A-Za-z]{3}$').hasMatch(cleanQuery)) {
        final parts = cleanQuery.split(RegExp(r'[\s-]+'));
        if (parts.length == 2) {
          print('🔍 Searching flights by route: ${parts[0]} → ${parts[1]}');
          final flights = await RihlaApiService.searchFlights(
            origin: parts[0],
            destination: parts[1],
          );
          foundFlights.addAll(flights);
        }
      }
      // 3. Check for single airport code
      else if (cleanQuery.length == 3) {
        print('🔍 Searching flights by airport: $cleanQuery');
        final flights = await RihlaApiService.fetchFlightsByAirport(cleanQuery);
        foundFlights.addAll(flights.take(15)); // Limit results
      }
      // 4. City name search
      else {
        print('🔍 Searching by city/airport name: $query');
        final matchingAirports = dummyAirports.where((airport) {
          return airport.city.toLowerCase().contains(query.toLowerCase()) ||
              airport.name.toLowerCase().contains(query.toLowerCase());
        }).toList();

        if (matchingAirports.isNotEmpty) {
          // Take the first matching airport
          final airportCode = matchingAirports.first.code;
          final flights = await RihlaApiService.fetchFlightsByAirport(
            airportCode,
          );
          foundFlights.addAll(flights.take(10));
        }
      }

      setState(() {
        searchResults = foundFlights;
        isSearching = false;
      });

      print('✅ Search completed: ${foundFlights.length} results');
    } catch (e) {
      print('❌ Search error: $e');
      setState(() {
        searchResults = [];
        isSearching = false;
      });
    }
  }

  // Add these constants at top of _HomeScreenContentState class
  final List<Map<String, dynamic>> _searchCategories = [
    {
      'icon': Icons.flight_takeoff,
      'label': 'Flights',
      'color': Color(0xFFFDC64C),
      'examples': ['QR740', 'PK203', 'EK625'],
    },
    {
      'icon': Icons.route,
      'label': 'Routes',
      'color': Color(0xFF1E90FF),
      'examples': ['LHE DXB', 'KHI DOH', 'ISB IST'],
    },
    {
      'icon': Icons.airplanemode_active,
      'label': 'Airports',
      'color': Color(0xFF4CAF50),
      'examples': ['DXB', 'LHE', 'KHI'],
    },
    {
      'icon': Icons.business,
      'label': 'Airlines',
      'color': Color(0xFF9C27B0),
      'examples': ['QR', 'EK', 'PK'],
    },
  ];

  final List<Map<String, dynamic>> _recentSearches = [
    {'query': 'QR740', 'type': 'flight'},
    {'query': 'LHE DXB', 'type': 'route'},
    {'query': 'KHI', 'type': 'airport'},
    {'query': 'Qatar Airways', 'type': 'airline'},
  ];

  // ========== REPLACE THE ENTIRE buildSearchBar() METHOD WITH THIS ==========
  Widget buildSearchBar() {
    return Column(
      children: [
        // Hero Search Container
        Container(
          margin: EdgeInsets.symmetric(
            horizontal: responsiveValue(
              context,
              mobile: 16.0,
              tablet: 24.0,
              desktop: 32.0,
            ),
            vertical: 16.0,
          ),
          padding: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFDC64C),
                const Color(0xFF1E90FF),
                const Color(0xFF4CAF50),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 25,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 0),
            decoration: BoxDecoration(
              color: const Color(0xFF161F34),
              borderRadius: BorderRadius.circular(19),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, color: Color(0xFFFDC64C), size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText:
                          'Search flights, routes, airports, or airlines...',
                      hintStyle: const TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    onChanged: performSearch,
                    onTap: () {
                      setState(() {
                        _showSearchOverlay = true;
                      });
                    },
                  ),
                ),
                if (searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(
                      Icons.clear,
                      color: Colors.white54,
                      size: 20,
                    ),
                    onPressed: () {
                      searchController.clear();
                      performSearch('');
                      _searchFocusNode.unfocus();
                      setState(() {
                        _showSearchOverlay = false;
                      });
                    },
                  ),
                IconButton(
                  icon: Icon(
                    _showSearchOverlay
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: const Color(0xFFFDC64C),
                    size: 24,
                  ),
                  onPressed: () {
                    setState(() {
                      _showSearchOverlay = !_showSearchOverlay;
                      if (_showSearchOverlay) {
                        _searchFocusNode.requestFocus();
                      } else {
                        _searchFocusNode.unfocus();
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        ),

        // Search overlay with multiple sections
        if (_showSearchOverlay) _buildSearchOverlay(),
      ],
    );
  }

  // ========== PASTE ALL THESE METHODS AFTER buildSearchBar() ==========

  Widget _buildSearchOverlay() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 400;

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: responsiveValue(
          context,
          mobile: 16.0,
          tablet: 24.0,
          desktop: 32.0,
        ),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF161F34),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 30,
            spreadRadius: 5,
            offset: const Offset(0, 10),
          ),
        ],
        border: Border.all(
          color: const Color(0xFFFDC64C).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search header with tabs
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF0C1324),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              border: Border(
                bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  searchController.text.isEmpty
                      ? 'Quick Search'
                      : 'Search Results',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (searchController.text.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDC64C).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _getSearchTypeLabel(),
                      style: const TextStyle(
                        color: Color(0xFFFDC64C),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Content area
          Expanded(
            child: searchController.text.isEmpty
                ? _buildQuickSearchView()
                : _buildSearchResultsView(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickSearchView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search categories
          const Text(
            'Search Categories',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _searchCategories.map((category) {
              return _buildSearchCategoryCard(category);
            }).toList(),
          ),

          const SizedBox(height: 24),

          // Recent searches
          const Text(
            'Recent Searches',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _recentSearches.map((search) {
              return _buildRecentSearchChip(search);
            }).toList(),
          ),

          const SizedBox(height: 24),

          // Popular routes
          const Text(
            'Popular Routes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _buildPopularRoutes(),
        ],
      ),
    );
  }

  Widget _buildSearchCategoryCard(Map<String, dynamic> category) {
    // Extract values with null safety
    final icon = category['icon'] as IconData? ?? Icons.search;
    final label = category['label'] as String? ?? '';
    final color = category['color'] as Color? ?? const Color(0xFFFDC64C);
    final examplesList = category['examples'] as List<dynamic>? ?? [];

    // Convert List<dynamic> to List<String>
    final examples = examplesList.map((e) => e.toString()).toList();

    return GestureDetector(
      onTap: () {
        final example = examples.isNotEmpty ? examples[0] : '';
        searchController.text = example;
        performSearch(example);
      },
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1324),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              examples.join(', '),
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentSearchChip(Map<String, dynamic> search) {
    // Extract values with null safety
    final query = search['query'] as String? ?? '';
    final type = search['type'] as String? ?? 'search';

    IconData getIcon() {
      switch (type) {
        case 'flight':
          return Icons.flight;
        case 'route':
          return Icons.route;
        case 'airport':
          return Icons.airplanemode_active;
        case 'airline':
          return Icons.business;
        default:
          return Icons.search;
      }
    }

    Color getColor() {
      switch (type) {
        case 'flight':
          return const Color(0xFFFDC64C);
        case 'route':
          return const Color(0xFF1E90FF);
        case 'airport':
          return const Color(0xFF4CAF50);
        case 'airline':
          return const Color(0xFF9C27B0);
        default:
          return Colors.white;
      }
    }

    return GestureDetector(
      onTap: () {
        searchController.text = query;
        performSearch(query);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: getColor().withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: getColor().withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(getIcon(), color: getColor(), size: 16),
            const SizedBox(width: 8),
            Text(
              query,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopularRoutes() {
    final popularRoutes = [
      {
        'route': 'LHE → DXB',
        'airlines': ['PK', 'FZ', 'EK'],
        'duration': '3h 30m',
      },
      {
        'route': 'KHI → DOH',
        'airlines': ['QR', 'PK', 'SV'],
        'duration': '2h 45m',
      },
      {
        'route': 'ISB → IST',
        'airlines': ['TK', 'PK'],
        'duration': '5h 15m',
      },
      {
        'route': 'LHE → SHJ',
        'airlines': ['9P', 'PA'],
        'duration': '3h 15m',
      },
    ];

    return Column(
      children: popularRoutes.map((route) {
        // Extract values with null safety
        final routeStr = route['route'] as String? ?? '';
        final airlinesList = route['airlines'] as List<dynamic>? ?? [];
        final duration = route['duration'] as String? ?? '';

        // Convert List<dynamic> to List<String>
        final airlines = airlinesList.map((e) => e.toString()).toList();

        return GestureDetector(
          onTap: () {
            final parts = routeStr.split(' → ');
            if (parts.length == 2) {
              searchController.text = '${parts[0]} ${parts[1]}';
              performSearch('${parts[0]} ${parts[1]}');
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0C1324),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E90FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.route,
                      color: Color(0xFF1E90FF),
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        routeStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${airlines.join(', ')} • $duration',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white54,
                  size: 16,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _getSearchTypeLabel() {
    final query = searchController.text.trim().toUpperCase();

    if (RegExp(r'^[A-Z]{2}\d+$').hasMatch(query)) {
      return 'Flight Number';
    } else if (RegExp(r'^[A-Z]{3}\s+[A-Z]{3}$').hasMatch(query) ||
        RegExp(r'^[A-Z]{3}-[A-Z]{3}$').hasMatch(query)) {
      return 'Route';
    } else if (query.length == 3 && query == query.toUpperCase()) {
      return 'Airport Code';
    } else {
      return 'City/Airport';
    }
  }

  Widget _buildSearchResultsView() {
    return Column(
      children: [
        // Loading or results count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
          ),
          child: Row(
            children: [
              if (isSearching) ...[
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFFDC64C),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Searching...',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ] else ...[
                Icon(
                  searchResults.isNotEmpty
                      ? Icons.check_circle
                      : Icons.search_off,
                  color: searchResults.isNotEmpty
                      ? const Color(0xFF4CAF50)
                      : Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  searchResults.isNotEmpty
                      ? '${searchResults.length} result${searchResults.length > 1 ? 's' : ''} found'
                      : 'No results found',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
              const Spacer(),
              if (!isSearching && searchResults.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    // View all results
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SearchResultsScreen(
                          query: searchController.text,
                          results: searchResults,
                          searchType: _getSearchTypeLabel(),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E90FF).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'View All',
                      style: TextStyle(
                        color: Color(0xFF1E90FF),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Results list
        Expanded(
          child: isSearching
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Color(0xFFFDC64C)),
                      SizedBox(height: 16),
                      Text(
                        'Searching across multiple sources...',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : searchResults.isEmpty
              ? _buildNoResultsView()
              : ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: min(
                    searchResults.length,
                    5,
                  ), // Show max 5 in overlay
                  itemBuilder: (context, index) {
                    return _buildSearchResultItem(searchResults[index], index);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildNoResultsView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFFDC64C).withOpacity(0.1),
                borderRadius: BorderRadius.circular(40),
              ),
              child: const Icon(
                Icons.search_off,
                color: Color(0xFFFDC64C),
                size: 40,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No results found',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Try searching with:\n• Flight numbers (QR740)\n• Routes (LHE DXB)\n• Airport codes (DXB)\n• City names (Dubai)\n• Airline names (Qatar Airways)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultItem(RihlaFlightData flight, int index) {
    final airlineLogoUrl = AirlineService.getAirlineLogoUrl(flight.airline);
    final airlineName = AirlineService.getAirlineName(flight.airline);

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 0,
        maxWidth: MediaQuery.of(context).size.width - 32, // Account for padding
      ),
      child: GestureDetector(
        onTap: () => showFlightDetails(flight),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0C1324),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Airline logo
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      airlineLogoUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: const Color(0xFF1E90FF).withOpacity(0.1),
                          child: Center(
                            child: Text(
                              flight.airline.length >= 2
                                  ? flight.airline.substring(0, 2).toUpperCase()
                                  : '✈️',
                              style: const TextStyle(
                                color: Color(0xFF1E90FF),
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(width: 16),

                // Flight details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        flight.flightNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${flight.origin} → ${flight.destination}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.flight_takeoff,
                                size: 14,
                                color: Colors.green,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                flight.departureTime,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          Row(
                            children: [
                              Icon(
                                Icons.flight_land,
                                size: 14,
                                color: Colors.orange,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                flight.arrivalTime,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            flight.duration,
                            style: const TextStyle(
                              color: Color(0xFFFDC64C),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Quick action button
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    // Quick add to trips
                    final newFlight = Flight(
                      city:
                          mapCities[flight.destination]?.name ??
                          flight.destination,
                      route: '${flight.origin} → ${flight.destination}',
                      flightNumber: flight.flightNumber,
                      status: 'Scheduled',
                      airline: flight.airline,
                      departureTime: flight.departureTime,
                      arrivalTime: flight.arrivalTime,
                      duration: flight.duration,
                      aircraft: flight.aircraft,
                      origin: flight.origin,
                      destination: flight.destination,
                      flightDate: DateTime.now().add(const Duration(days: 7)),
                    );

                    FlightManager().addUserFlight(newFlight);

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '✅ ${flight.flightNumber} added to trips!',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: Colors.green,
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4CAF50).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.add,
                      color: Color(0xFF4CAF50),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Update the buildSearchResults method
  Widget buildSearchResults() {
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: responsiveValue(
          context,
          mobile: 16.0,
          tablet: 24.0,
          desktop: 32.0,
        ),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
        minHeight: 200,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    isSearching
                        ? 'Searching...'
                        : '${searchResults.length} result${searchResults.length != 1 ? 's' : ''} found',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!isSearching && searchResults.isNotEmpty)
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
              ],
            ),
          ),

          // Results list - FIXED: Use Expanded with constraints
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: isSearching
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Color(0xFF1E90FF)),
                          SizedBox(height: 16),
                          Text('Searching flights...'),
                        ],
                      ),
                    )
                  : searchResults.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search_off,
                            size: 60,
                            color: Colors.grey.shade300,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No flights found',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8),
                      shrinkWrap: true,
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        return _buildFlightResultItem(searchResults[index]);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlightResultItem(RihlaFlightData flight) {
    // TRANSFORM API DATA INTO USER-FRIENDLY FORMAT
    final airlineName = AirlineService.getAirlineName(flight.airline);
    final airlineLogoUrl = AirlineService.getAirlineLogoUrl(flight.airline);

    // Format times for display
    final departureTime = _formatTimeForDisplay(flight.departureTime);
    final arrivalTime = _formatTimeForDisplay(flight.arrivalTime);

    // Get city names from airport codes
    final originCity = _getCityName(flight.origin);
    final destinationCity = _getCityName(flight.destination);

    // Calculate duration in hours/minutes if not already formatted
    String displayDuration = flight.duration;
    if (flight.duration.contains('hr') || flight.duration.contains('min')) {
      // Already formatted by API
    } else if (flight.duration.contains(':')) {
      // Convert "03:35" to "3h 35m"
      final parts = flight.duration.split(':');
      if (parts.length == 2) {
        final hours = int.tryParse(parts[0]) ?? 0;
        final minutes = int.tryParse(parts[1]) ?? 0;
        displayDuration = '${hours}h ${minutes}m';
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showFlightDetails(flight),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Airline and Flight Info
                Row(
                  children: [
                    // Airline Logo
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          airlineLogoUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: const Color(0xFF1E90FF).withOpacity(0.1),
                              child: Center(
                                child: Text(
                                  airlineName.substring(0, 1),
                                  style: const TextStyle(
                                    color: Color(0xFF1E90FF),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 20,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Airline and Route Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            airlineName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$originCity → $destinationCity',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.black54,
                            ),
                          ),
                          Text(
                            'Flight ${flight.flightNumber} • ${flight.aircraft}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Flight Timeline
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          departureTime,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                        Text(
                          flight.origin,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                        Text(
                          originCity,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),

                    // Duration in middle
                    Column(
                      children: [
                        Icon(
                          Icons.flight_takeoff,
                          color: Colors.blue.shade600,
                          size: 20,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          displayDuration,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue.shade600,
                          ),
                        ),
                      ],
                    ),

                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          arrivalTime,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                        Text(
                          flight.destination,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                        Text(
                          destinationCity,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // Status and Action
                const SizedBox(height: 12),
                Divider(height: 1, color: Colors.grey.shade300),
                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Status Badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: Colors.green.shade600,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Scheduled',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Quick Add Button
                    ElevatedButton.icon(
                      onPressed: () {
                        _addFlightToTrips(flight);
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add to Trips'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E90FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helper methods for data transformation
  String _formatTimeForDisplay(String time24) {
    try {
      final parts = time24.split(':');
      if (parts.length != 2) return time24;

      int hour = int.parse(parts[0]);
      int minute = int.parse(parts[1]);

      String period = hour >= 12 ? 'PM' : 'AM';
      hour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);

      return '${hour.toString()}:${minute.toString().padLeft(2, '0')} $period';
    } catch (e) {
      return time24;
    }
  }

  String _getCityName(String airportCode) {
    // Try to get from mapCities first
    final cityLocation = mapCities[airportCode];
    if (cityLocation != null) return cityLocation.name;

    // Try to get from dummyAirports
    final airport = dummyAirports.firstWhere(
      (a) => a.code == airportCode,
      orElse: () => Airport(
        name: 'Unknown',
        code: airportCode,
        city: airportCode,
        country: '',
      ),
    );

    return airport.city;
  }

  Future<void> _addFlightToTrips(RihlaFlightData flight) async {
    final flightManager = FlightManager();

    // Ensure FlightManager is initialized
    if (!flightManager.isInitialized) {
      await flightManager.init();
    }

    final newFlight = Flight(
      city: _getCityName(flight.destination),
      route:
          '${_getCityName(flight.origin)} → ${_getCityName(flight.destination)}',
      flightNumber: flight.flightNumber,
      status: 'Scheduled',
      airline: AirlineService.getAirlineName(flight.airline),
      departureTime: _formatTimeForDisplay(flight.departureTime),
      arrivalTime: _formatTimeForDisplay(flight.arrivalTime),
      duration: flight.duration,
      aircraft: flight.aircraft,
      origin: flight.origin,
      destination: flight.destination,
      flightDate: DateTime.now().add(const Duration(days: 7)),
    );

    await flightManager.addUserFlight(newFlight);

    // Show success message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✓ ${AirlineService.getAirlineName(flight.airline)} ${flight.flightNumber} added to trips!',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void showFlightDetails(RihlaFlightData flight) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FlightDetailsBottomSheet(flight: flight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      body: SafeArea(
        bottom: false,
        child: GestureDetector(
          onTap: () {
            _searchFocusNode.unfocus();
          },
          child: Column(
            children: [
              buildSearchBar(),
              // Use Expanded with constraints to avoid overflow
              if (isSearching || searchController.text.isNotEmpty)
                Expanded(child: buildSearchResults())
              else
                Expanded(child: buildHomeContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildHomeContent() {
    return FutureBuilder<RecommendationResponse>(
      future: recommendations,
      builder: (context, snapshot) {
        // Show loading state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFFDC64C)),
          );
        }

        // Show error state
        if (snapshot.hasError) {
          print('❌ Error loading recommendations: ${snapshot.error}');
          return buildErrorMessage(
            'Failed to load content',
            'Please check your connection and try again',
          );
        }

        // Check if data is valid
        if (!snapshot.hasData ||
            (snapshot.data!.destinations.isEmpty &&
                snapshot.data!.deals.isEmpty)) {
          return buildErrorMessage(
            'No content available',
            'Try again later or check your connection',
          );
        }

        final data = snapshot.data!;
        return buildHomeContentWithData(data);
      },
    );
  }

  Widget buildErrorMessage(String title, String message) {
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 80,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    recommendations = _fetchRecommendationsWithRetry();
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFDC64C),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Try Again',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildHomeContentWithData(RecommendationResponse data) {
    // VALIDATE DATA BEFORE SHOWING
    final validDestinations = data.destinations.where((dest) {
      final hasTitle =
          dest.title.isNotEmpty && dest.title != 'Unknown Destination';
      final hasValidImage =
          dest.imageUrl.isNotEmpty &&
          dest.imageUrl.startsWith('http') &&
          !dest.imageUrl.contains('undefined');
      return hasTitle && hasValidImage;
    }).toList();

    final validDeals = data.deals.where((deal) {
      final hasName = deal.name.isNotEmpty && deal.name != 'Unknown Deal';
      final hasValidImage =
          deal.imageUrl.isNotEmpty &&
          deal.imageUrl.startsWith('http') &&
          !deal.imageUrl.contains('undefined');
      return hasName && hasValidImage;
    }).toList();

    // Show empty state if no valid data
    if (validDestinations.isEmpty && validDeals.isEmpty) {
      return buildErrorMessage(
        'No recommendations available',
        'Check back later for travel suggestions',
      );
    }

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        // Destinations section - only if we have data
        if (validDestinations.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                const Padding(
                  padding: EdgeInsets.only(left: 20.0, bottom: 16.0),
                  child: Text(
                    'Popular Destinations',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 280,
              child: PageView.builder(
                controller: pageController,
                onPageChanged: (int page) {
                  setState(() {
                    currentPage = page;
                  });
                },
                itemCount: validDestinations.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: EdgeInsets.only(
                      left: index == 0 ? 20 : 10,
                      right: index == validDestinations.length - 1 ? 20 : 10,
                    ),
                    child: DestinationCard(
                      destination: validDestinations[index],
                    ),
                  );
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    validDestinations.length,
                    (index) => Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4.0),
                      width: currentPage == index ? 12.0 : 8.0,
                      height: 8.0,
                      decoration: BoxDecoration(
                        shape: currentPage == index
                            ? BoxShape.rectangle
                            : BoxShape.circle,
                        borderRadius: currentPage == index
                            ? BorderRadius.circular(4)
                            : null,
                        color: currentPage == index
                            ? const Color(0xFFFDC64C)
                            : Colors.white30,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Deals section - only if we have data
        if (validDeals.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 40),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Special Deals',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Icon(Icons.local_offer, color: Color(0xFFFDC64C)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16.0,
                mainAxisSpacing: 16.0,
                childAspectRatio: 0.8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => DealGridItem(deal: validDeals[index]),
                childCount: validDeals.length,
              ),
            ),
          ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

// Add FlightDetailsBottomSheet widget
class FlightDetailsBottomSheet extends StatelessWidget {
  final RihlaFlightData flight;

  const FlightDetailsBottomSheet({super.key, required this.flight});

  // Update the FlightDetailsBottomSheet build method
  @override
  Widget build(BuildContext context) {
    final airlineName = AirlineService.getAirlineName(flight.airline);
    final airlineLogoUrl = AirlineService.getAirlineLogoUrl(flight.airline);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header - FIXED: Added Expanded for content
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                // Airline Logo
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      airlineLogoUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: const Color(0xFF1E90FF),
                          child: Center(
                            child: Text(
                              flight.airline.length >= 2
                                  ? flight.airline.substring(0, 2).toUpperCase()
                                  : '✈️',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        airlineName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${flight.origin} → ${flight.destination}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Flight ${flight.flightNumber}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Flight details - FIXED: Use Flexible with SingleChildScrollView
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDetailRow('Airline', airlineName),
                  _buildDetailRow('Aircraft', flight.aircraft),
                  _buildDetailRow(
                    'Departure',
                    '${flight.origin} • ${flight.departureTime}',
                  ),
                  _buildDetailRow(
                    'Arrival',
                    '${flight.destination} • ${flight.arrivalTime}',
                  ),
                  _buildDetailRow('Duration', flight.duration),
                  if (flight.lastChecked != null)
                    _buildDetailRow(
                      'Last Updated',
                      _formatLastChecked(flight.lastChecked!),
                    ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.grey),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E90FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Add to Trips',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatLastChecked(String timestamp) {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inDays > 0) {
        return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
      } else {
        return 'Just now';
      }
    } catch (e) {
      return timestamp;
    }
  }
}

/// Widget that displays flight info with cycling animation between 3 states
class AnimatedFlightCard extends StatefulWidget {
  final Flight flight;
  final VoidCallback? onTap;

  const AnimatedFlightCard({super.key, required this.flight, this.onTap});

  @override
  State<AnimatedFlightCard> createState() => _AnimatedFlightCardState();
}

class _AnimatedFlightCardState extends State<AnimatedFlightCard> {
  int _currentState = 0;
  Timer? _timer;
  static const _cycleDurationMs = 3000;

  @override
  void initState() {
    super.initState();
    // Calculate initial state based on current time for sync across all cards
    final now = DateTime.now().millisecondsSinceEpoch;
    _currentState = (now ~/ _cycleDurationMs) % 3;

    // Align timer to next 3-second boundary
    final msUntilNext = _cycleDurationMs - (now % _cycleDurationMs);
    Future.delayed(Duration(milliseconds: msUntilNext), () {
      if (mounted) {
        setState(() => _currentState = (_currentState + 1) % 3);
        _timer = Timer.periodic(
          const Duration(milliseconds: _cycleDurationMs),
          (_) {
            if (mounted)
              setState(() => _currentState = (_currentState + 1) % 3);
          },
        );
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double _calculateDistance() {
    final origin = mapCities[widget.flight.origin];
    final dest = mapCities[widget.flight.destination];
    if (origin == null || dest == null) return 0;

    // Haversine formula for distance
    const R = 6371.0; // Earth radius in km
    final lat1 = origin.lat * pi / 180;
    final lat2 = dest.lat * pi / 180;
    final dLat = (dest.lat - origin.lat) * pi / 180;
    final dLon = (dest.lon - origin.lon) * pi / 180;

    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  // In AnimatedFlightCard, update the _formatDate method:
  String _formatDate() {
    final d = widget.flight.flightDate;
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    // Get weekday (0=Monday in Dart's DateTime, but adjust to start with Monday)
    final weekdayIndex = (d.weekday + 6) % 7; // Convert to Mon=0, Sun=6
    return '${days[weekdayIndex]} ${d.day} ${months[d.month - 1]}';
  }

  String _formatDaysLeft() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final flightDay = DateTime(
      widget.flight.flightDate.year,
      widget.flight.flightDate.month,
      widget.flight.flightDate.day,
    );

    final difference = flightDay.difference(today).inDays;

    if (difference == 0) return 'Today';
    if (difference == 1) return 'Tomorrow';
    if (difference == 2) return 'Day after tomorrow';
    if (difference < 7) return '$difference Days Left';
    if (difference < 30)
      return '${difference ~/ 7} Week${difference ~/ 7 == 1 ? '' : 's'} Left';
    return '${difference ~/ 30} Month${difference ~/ 30 == 1 ? '' : 's'} Left';
  }

  Widget _buildStateContent(String airlineName) {
    // For connecting flights, show different content
    final isConnectingFlight = widget.flight.route.contains('→ ... →');

    switch (_currentState) {
      case 0:
        // State 1: Days Left + Aircraft
        final daysText = _formatDaysLeft();
        final isUrgent = _calculateDaysLeft() <= 3;

        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    color: isUrgent
                        ? Colors.red.shade700
                        : Colors.orange.shade700,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      daysText,
                      style: TextStyle(
                        color: isUrgent
                            ? Colors.red.shade700
                            : Colors.orange.shade700,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  airlineName.isNotEmpty ? airlineName : 'Aircraft TBD',
                  style: TextStyle(color: Colors.blue.shade700, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        );

      case 1:
        // State 2: Route Information
        if (isConnectingFlight) {
          // Show connecting flight info
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.flight.route.replaceAll('→ ... →', '→ ... →'),
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  'Flight ${widget.flight.flightNumber}',
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  'Connecting flight',
                  style: TextStyle(
                    color: Colors.orange.shade700,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          );
        } else {
          // Regular flight
          final distance = _calculateDistance();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.flight.city,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  '${widget.flight.route}  ${widget.flight.flightNumber}',
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  'Distance: ${distance.toStringAsFixed(0)} km',
                  style: const TextStyle(color: Colors.black45, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          );
        }

      case 2:
        // State 3: Date + Times + Duration
        if (isConnectingFlight) {
          // Show total duration for connecting flights
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _formatDate(),
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  'Total Duration: ${widget.flight.duration}',
                  style: TextStyle(
                    color: Colors.purple.shade700,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  '${widget.flight.departureTime} → ${widget.flight.arrivalTime}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          );
        } else {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _formatDate(),
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    Icons.flight_takeoff,
                    size: 14,
                    color: Colors.green.shade600,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      widget.flight.departureTime.isNotEmpty
                          ? widget.flight.departureTime
                          : '--:--',
                      style: TextStyle(
                        color: Colors.green.shade700,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.flight_land,
                    size: 14,
                    color: Colors.orange.shade600,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      widget.flight.arrivalTime.isNotEmpty
                          ? widget.flight.arrivalTime
                          : '--:--',
                      style: TextStyle(
                        color: Colors.orange.shade700,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  'Duration: ${widget.flight.duration.isNotEmpty ? widget.flight.duration : "-"}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          );
        }

      default:
        return const SizedBox.shrink();
    }
  }

  int _calculateDaysLeft() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final flightDay = DateTime(
      widget.flight.flightDate.year,
      widget.flight.flightDate.month,
      widget.flight.flightDate.day,
    );
    return flightDay.difference(today).inDays;
  }

  @override
  Widget build(BuildContext context) {
    final airlineLogoUrl = AirlineService.getAirlineLogoUrl(
      widget.flight.airline,
    );
    final airlineName = AirlineService.getAirlineName(widget.flight.airline);

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 80),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            // Airline logo
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  airlineLogoUrl,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: const Color(0xFF1E90FF),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: const Color(0xFFE53935),
                      child: Center(
                        child: Text(
                          widget.flight.airline.length >= 2
                              ? widget.flight.airline
                                    .substring(0, 2)
                                    .toUpperCase()
                              : '✈️',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Animated content area - FIXED: Use Flexible instead of Expanded
            Flexible(
              flex: 1,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.1),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  key: ValueKey<int>(_currentState),
                  constraints: const BoxConstraints(minHeight: 40),
                  child: _buildStateContent(airlineName),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => TripsScreenState();
}

// Replace the entire TripsScreenState class with this:

class TripsScreenState extends State<TripsScreen> {
  final MapController mapController = MapController();
  double currentZoom = 2.5;
  bool _isLoadingPast = true;
  bool _showPastFlightsView = false;
  bool _isMapInitialized = false;
  final FlightManager _flightManager = FlightManager();

  // Major hubs for map
  static const Set<String> majorHubs = {
    // Middle East & Asia
    'DXB', 'DOH', 'AUH', 'IST', 'KUL', 'SIN', 'HKG', 'ICN',
    'NRT', 'DEL', 'BOM', 'KHI', 'LHE', 'ISB', 'RUH', 'JED',
    // Europe
    'LHR', 'CDG', 'FRA', 'AMS', 'MAD', 'FCO', 'MUC', 'ZRH',
    // North America
    'JFK', 'LAX', 'ORD', 'ATL', 'DFW', 'MIA', 'YYZ', 'MEX',
    // Oceania & Africa
    'SYD', 'MEL', 'AKL', 'JNB', 'CPT', 'CAI', 'NBO',
  };

  @override
  void initState() {
    super.initState();
    _initializeFlights();

    // Initialize map after a short delay
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _isMapInitialized = true;
        });
        _autoZoomToUserFlights();
      }
    });
  }

  @override
  void dispose() {
    mapController.dispose();
    _flightManager.close(); // Close Hive boxes
    super.dispose();
  }

  Future<void> _initializeFlights() async {
    try {
      // Initialize FlightManager with Hive
      await _flightManager.init();

      // NO API loading for past flights anymore
      // Past flights only come from upcoming flights that have passed

      if (mounted) {
        setState(() {
          _isLoadingPast = false;
        });
      }
    } catch (e) {
      print('❌ Error initializing flights: $e');
      if (mounted) {
        setState(() {
          _isLoadingPast = false;
        });
      }
    }
  }

  void _autoZoomToUserFlights() {
    if (!_isMapInitialized || _flightManager.upcomingFlights.isEmpty) {
      // Show default world view
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          try {
            mapController.move(const LatLng(25.0, 20.0), 2.5);
          } catch (e) {
            print('Map move error (expected on first load): $e');
          }
        }
      });
      return;
    }

    final points = <LatLng>[];
    for (final flight in _flightManager.upcomingFlights) {
      final origin = mapCities[flight.origin];
      final dest = mapCities[flight.destination];
      if (origin != null) points.add(LatLng(origin.lat, origin.lon));
      if (dest != null) points.add(LatLng(dest.lat, dest.lon));
    }

    if (points.isEmpty) {
      // Show default world view
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          try {
            mapController.move(const LatLng(25.0, 20.0), 2.5);
          } catch (e) {
            print('Map move error: $e');
          }
        }
      });
      return;
    }

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        try {
          mapController.move(LatLng(centerLat, centerLng), 4.0);
        } catch (e) {
          print('Auto-zoom error: $e');
        }
      }
    });
  }

  String _formatFlightDate(DateTime date) {
    final now = DateTime.now();
    final difference = date.difference(now);

    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Tomorrow';
    } else if (difference.inDays > 0) {
      return 'In ${difference.inDays} days';
    } else {
      // Past flight
      final daysAgo = -difference.inDays;
      if (daysAgo == 1) return 'Yesterday';
      if (daysAgo < 7) return '$daysAgo days ago';
      if (daysAgo < 30)
        return '${daysAgo ~/ 7} week${daysAgo ~/ 7 == 1 ? '' : 's'} ago';
      return '${daysAgo ~/ 30} month${daysAgo ~/ 30 == 1 ? '' : 's'} ago';
    }
  }

  List<Marker> _buildAirportMarkers() {
    final markers = <Marker>[];
    if (mapCities.isEmpty || !_flightManager.isInitialized) return markers;

    // User's flight airports
    final userAirports = <String>{};
    for (final flight in _flightManager.upcomingFlights) {
      userAirports.add(flight.origin);
      userAirports.add(flight.destination);
    }

    // Filter valid airport codes
    final validMapCities = mapCities.entries.where((entry) {
      final code = entry.key;
      return code.length == 3 &&
          code.toUpperCase() == code &&
          !code.contains(RegExp(r'[0-9]'));
    }).toList();

    // Determine which airports to show
    final airportsToShow = <String>{};

    if (currentZoom < 3) {
      airportsToShow.addAll(
        majorHubs.where(
          (code) => validMapCities.any((entry) => entry.key == code),
        ),
      );
    } else if (currentZoom < 5) {
      airportsToShow.addAll(
        majorHubs.where(
          (code) => validMapCities.any((entry) => entry.key == code),
        ),
      );
      for (int i = 0; i < validMapCities.length; i += 10) {
        airportsToShow.add(validMapCities[i].key);
      }
    } else {
      for (int i = 0; i < validMapCities.length; i += 5) {
        airportsToShow.add(validMapCities[i].key);
      }
    }

    // Always include user's airports
    airportsToShow.addAll(
      userAirports.where(
        (code) => validMapCities.any((entry) => entry.key == code),
      ),
    );

    for (final code in airportsToShow) {
      final city = mapCities[code];
      if (city == null) continue;
      final isUserAirport = userAirports.contains(code);
      markers.add(_buildAirportMarker(city, code, isUserAirport));
    }

    return markers;
  }

  Marker _buildAirportMarker(
    CityLocation city,
    String code,
    bool isUserAirport,
  ) {
    if (isUserAirport) {
      return Marker(
        point: LatLng(city.lat, city.lon),
        width: 100,
        height: 45,
        child: GestureDetector(
          onTap: () => _onAirportTapped(city, code),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: const Color(0xFFFDC64C), width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFDC64C).withOpacity(0.5),
                  blurRadius: 15,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.flight, color: Color(0xFFFDC64C), size: 18),
                const SizedBox(width: 6),
                Text(
                  code,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Marker(
      point: LatLng(city.lat, city.lon),
      width: 50,
      height: 30,
      child: GestureDetector(
        onTap: () => _onAirportTapped(city, code),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.blue.shade300, width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4),
            ],
          ),
          child: Center(
            child: Text(
              code,
              style: TextStyle(
                color: Colors.blue.shade700,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onAirportTapped(CityLocation city, String code) {
    final airport = dummyAirports.firstWhere(
      (a) => a.code == code,
      orElse: () => Airport(
        name: city.name,
        code: code,
        city: city.name,
        country: 'Unknown',
      ),
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddFlightScreen(preSelectedOrigin: airport),
      ),
    ).then((_) {
      // Refresh when returning
      if (mounted) {
        setState(() {});
        _autoZoomToUserFlights();
      }
    });
  }

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8),
          ],
        ),
        child: Icon(icon, color: Colors.black, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      body: Stack(
        children: [
          // Map - ALWAYS RENDERED
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: const LatLng(25.0, 20.0),
              initialZoom: 2.5,
              minZoom: 2.0,
              maxZoom: 8.0,
              onPositionChanged: (position, hasGesture) {
                if (position.zoom != null && position.zoom != currentZoom) {
                  setState(() {
                    currentZoom = position.zoom!;
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.rihla.travel',
              ),
              PolylineLayer(polylines: _buildFlightRoutes()),
              MarkerLayer(markers: _buildAirportMarkers()),
            ],
          ),

          // Loading overlay - SIMPLIFIED
          if (_isLoadingPast)
            Container(
              color: const Color(0xFF0C1324).withOpacity(0.8),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFFDC64C)),
                    SizedBox(height: 16),
                    Text(
                      'Loading flight data...',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ],
                ),
              ),
            )
          else if (!_flightManager.isInitialized)
            Container(
              color: const Color(0xFF0C1324).withOpacity(0.8),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Flight data not initialized',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _initializeFlights,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFDC64C),
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            // Top gradient
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 120,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0C1324).withOpacity(0.9),
                      const Color(0xFF0C1324).withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),

            // Back button
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              child: GestureDetector(
                onTap: () =>
                    MainScreen.mainScreenKey.currentState?.navigateToTab(0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.arrow_back,
                    color: Colors.black,
                    size: 24,
                  ),
                ),
              ),
            ),

            // Zoom controls
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 16,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Text(
                      'Zoom: ${currentZoom.toStringAsFixed(1)}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Zoom in
                  _buildZoomButton(Icons.add, () {
                    try {
                      final newZoom = (mapController.camera.zoom + 1).clamp(
                        2.0,
                        8.0,
                      );
                      mapController.move(mapController.camera.center, newZoom);
                    } catch (e) {
                      print('Zoom in error: $e');
                    }
                  }),
                  const SizedBox(height: 8),
                  // Zoom out
                  _buildZoomButton(Icons.remove, () {
                    try {
                      final newZoom = (mapController.camera.zoom - 1).clamp(
                        2.0,
                        8.0,
                      );
                      mapController.move(mapController.camera.center, newZoom);
                    } catch (e) {
                      print('Zoom out error: $e');
                    }
                  }),
                  const SizedBox(height: 8),
                  // Center on flights or world
                  _buildZoomButton(Icons.my_location, () {
                    try {
                      _autoZoomToUserFlights();
                    } catch (e) {
                      print('Center error: $e');
                    }
                  }),
                ],
              ),
            ),

            // Replace the entire DraggableScrollableSheet section (around line ~500) with:

            // Bottom sheet - FIXED: Added constraints to prevent render overflow
            // Replace the entire DraggableScrollableSheet section (~line 470) with:

            // Bottom sheet - FIXED: Added constraints to prevent render overflow
            // Bottom sheet - FIXED: Proper background without transparency
            DraggableScrollableSheet(
              initialChildSize: 0.25,
              minChildSize: 0.1,
              maxChildSize: 0.6,
              snap: true,
              snapSizes: const [0.1, 0.25, 0.6],
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white, // SOLID WHITE BACKGROUND
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 15,
                        offset: Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag handle
                      Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),

                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            GestureDetector(
                              onTap: () => setState(
                                () => _showPastFlightsView =
                                    !_showPastFlightsView,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    _showPastFlightsView
                                        ? 'Past Flights'
                                        : 'My Upcoming Flights',
                                    style: TextStyle(
                                      color: _showPastFlightsView
                                          ? Colors.blue.shade700
                                          : const Color(0xFFFDC64C),
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.swap_horiz,
                                    color: Colors.grey.shade500,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const AddFlightScreen(),
                                  ),
                                ).then((_) {
                                  if (mounted) {
                                    setState(() {});
                                    _autoZoomToUserFlights();
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _showPastFlightsView
                                      ? Colors.blue.shade100
                                      : const Color(0xFFFDC64C),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.add,
                                  color: _showPastFlightsView
                                      ? Colors.blue.shade700
                                      : Colors.black,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Content area
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          physics: const ClampingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          children: _showPastFlightsView
                              ? _buildPastFlightsList()
                              : _buildUpcomingFlightsList(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  // Update the _buildFlightRoutes method in TripsScreenState
  List<Polyline> _buildFlightRoutes() {
    final lines = <Polyline>[];
    if (mapCities.isEmpty || !_flightManager.isInitialized) return lines;

    final flights = _flightManager.upcomingFlights;
    if (flights.isEmpty) return lines;

    for (final flight in flights) {
      final startCity = mapCities[flight.origin];
      final endCity = mapCities[flight.destination];
      if (startCity == null || endCity == null) continue;

      lines.add(
        Polyline(
          points: [
            LatLng(startCity.lat, startCity.lon),
            LatLng(endCity.lat, endCity.lon),
          ],
          color: const Color(0xFFFDC64C),
          strokeWidth: 4.0,
          gradientColors: const [Color(0xFFFDC64C), Color(0xFFFFA726)],
        ),
      );
    }

    return lines;
  }

  // Update the _buildUpcomingFlightsList method
  List<Widget> _buildUpcomingFlightsList() {
    final flights = _flightManager.upcomingFlights;

    if (flights.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, color: Colors.grey, size: 40),
                ),
                const SizedBox(height: 16),
                const Text(
                  'No upcoming flights',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap + to add your first flight',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return flights.map((flight) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: MediaQuery.of(context).size.width - 40,
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Dismissible(
            key: ValueKey('${flight.flightNumber}-${flight.flightDate}'),
            direction: DismissDirection.endToStart,
            background: Container(
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white, size: 24),
            ),
            onDismissed: (_) => _removeFlight(flight),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: AnimatedFlightCard(flight: flight),
            ),
          ),
        ),
      );
    }).toList();
  }

  void _removeFlight(Flight flight) async {
    await _flightManager.removeUserFlight(flight);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed ${flight.flightNumber}'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  List<Widget> _buildPastFlightsList() {
    final flights = _flightManager.pastFlights;

    if (flights.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Column(
              children: [
                const Icon(Icons.history, color: Colors.grey, size: 40),
                const SizedBox(height: 10),
                const Text(
                  'No past flights yet',
                  style: TextStyle(color: Colors.black54, fontSize: 14),
                ),
                const SizedBox(height: 5),
                Text(
                  'When upcoming flights pass, they will appear here',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return flights.map((flight) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(Icons.flight_land, color: Colors.white, size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      flight.city,
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${flight.route}  ${flight.flightNumber}',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${flight.airline} • ${flight.aircraft}',
                      style: const TextStyle(
                        color: Colors.black45,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatFlightDate(flight.flightDate),
                      style: const TextStyle(
                        color: Colors.black38,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}

// Replace the entire FlightResultsScreen class with this updated version

class FlightResultsScreen extends StatefulWidget {
  final Airport origin;
  final Airport destination;
  final DateTime? departureDate;

  const FlightResultsScreen({
    super.key,
    required this.origin,
    required this.destination,
    this.departureDate,
  });

  @override
  State<FlightResultsScreen> createState() => _FlightResultsScreenState();
}

class _FlightResultsScreenState extends State<FlightResultsScreen> {
  List<FlightOffer> flightOffers = []; // Changed to FlightOffer list
  bool isLoading = true;
  String? errorMessage;
  final FlightManager _flightManager = FlightManager();

  @override
  void initState() {
    super.initState();
    loadFlightOffers();
  }

  Future<void> loadFlightOffers() async {
    print('═══════════════════════════════════════');
    print('🔍 FLIGHT OFFERS SEARCH DEBUG');
    print('Origin: ${widget.origin.code} (${widget.origin.city})');
    print(
      'Destination: ${widget.destination.code} (${widget.destination.city})',
    );

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Use the offers API for connecting flights
      if (widget.departureDate != null) {
        print('📅 Date-specific search detected, using Offers API');
        print(
          'Departure Date: ${widget.departureDate!.toIso8601String().split('T')[0]}',
        );

        final offers = await RihlaApiService.searchFlightOffers(
          origin: widget.origin.code,
          destination: widget.destination.code,
          departureDate: widget.departureDate!,
          currency: 'USD',
        );

        print('📊 Offers API Response: ${offers.length} offers found');

        setState(() {
          flightOffers = offers;
          isLoading = false;
        });
      } else {
        // Fallback to direct flights if no date specified
        print('ℹ️ No date specified, showing sample direct flights');

        // Create sample direct flight offers
        final sampleOffers = _createSampleDirectOffers();

        setState(() {
          flightOffers = sampleOffers;
          isLoading = false;
        });
      }
    } catch (e, stackTrace) {
      print('❌ API ERROR:');
      print('Error: $e');
      print('StackTrace: $stackTrace');

      setState(() {
        flightOffers = [];
        isLoading = false;
        errorMessage =
            'Failed to load flight offers. Please check your connection.';
      });
    }

    print('═══════════════════════════════════════\n');
  }

  List<FlightOffer> _createSampleDirectOffers() {
    // Create sample direct flight offers for when no date is specified
    final sampleFlights = [
      {
        'flight': 'PK785',
        'aircraft': 'B77W',
        'price': 850.0,
        'pricePkr': 241400,
        'departure': '14:30',
        'arrival': '18:45',
        'duration': 495,
        'duration_formatted': '8h 15m',
        'airline': 'PK',
      },
      {
        'flight': 'EK425',
        'aircraft': 'A380',
        'price': 920.0,
        'pricePkr': 261280,
        'departure': '22:15',
        'arrival': '02:30',
        'duration': 495,
        'duration_formatted': '8h 15m',
        'airline': 'EK',
      },
      {
        'flight': 'QR635',
        'aircraft': 'B789',
        'price': 780.0,
        'pricePkr': 221520,
        'departure': '09:45',
        'arrival': '14:00',
        'duration': 495,
        'duration_formatted': '8h 15m',
        'airline': 'QR',
      },
    ];

    return sampleFlights.map((flightData) {
      final segment = FlightOfferSegment(
        offerId: 1,
        flight: flightData['flight'] as String,
        aircraft: flightData['aircraft'] as String,
        ticketingUntil: DateTime.now()
            .add(const Duration(days: 7))
            .toIso8601String()
            .split('T')[0],
        price: flightData['price'] as double,
        pricePkr: flightData['pricePkr'] as int,
        date:
            widget.departureDate ?? DateTime.now().add(const Duration(days: 7)),
        origin: widget.origin.code,
        departure: flightData['departure'] as String,
        destination: widget.destination.code,
        arrival: flightData['arrival'] as String,
        checkedBag: BaggageInfo(weight: 30, weightUnit: 'KG', quantity: 1),
        distance: 6000.0,
        duration: flightData['duration'] as int,
        durationFormatted: flightData['duration_formatted'] as String,
        compositeScore: 0.8,
        rank: 1,
      );

      return FlightOffer(
        id: flightData['flight'].hashCode,
        segments: [segment],
        totalPrice: flightData['price'] as double,
        totalPricePkr: flightData['pricePkr'] as int,
        rank: 1,
        compositeScore: 0.8,
        totalTripDuration: flightData['duration_formatted'] as String,
        totalDisplayDuration: flightData['duration_formatted'] as String,
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1324),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${widget.origin.code} → ${widget.destination.code}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFFFDC64C)),
            SizedBox(height: 16),
            Text(
              'Searching flight offers...',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 80, color: Colors.red),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    errorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      isLoading = true;
                      errorMessage = null;
                    });
                    loadFlightOffers();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFDC64C),
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (flightOffers.isEmpty) {
      return SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.flight_takeoff,
                  size: 80,
                  color: Colors.white.withOpacity(0.3),
                ),
                const SizedBox(height: 16),
                const Text(
                  'No flight offers available',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.origin.code} → ${widget.destination.code}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                if (widget.departureDate != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Date: ${widget.departureDate!.toIso8601String().split('T')[0]}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Try Another Route'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFDC64C),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView(
      children: [
        // Header with count
        Container(
          padding: const EdgeInsets.all(16),
          color: const Color(0xFF161F34),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${flightOffers.length} offer${flightOffers.length != 1 ? 's' : ''} found',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Icon(
                Icons.check_circle,
                color: Color(0xFFFDC64C),
                size: 20,
              ),
            ],
          ),
        ),

        // Flight offers
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: flightOffers.map((flightOffer) {
              return FlightResultCard(
                flightOffer: flightOffer,
                origin: widget.origin,
                destination: widget.destination,
                departureDate: widget.departureDate,
                onTap: () async {
                  // Add the flight to trips
                  await _addFlightToTrips(flightOffer);
                },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Future<void> _addFlightToTrips(FlightOffer flightOffer) async {
    final flightManager = FlightManager();

    // Ensure FlightManager is initialized
    if (!flightManager.isInitialized) {
      await flightManager.init();
    }

    // For multi-leg trips, create a flight for the first segment
    // (In a more advanced implementation, you might want to store all segments)
    final firstSegment = flightOffer.segments.first;
    final departureDate =
        widget.departureDate ?? DateTime.now().add(const Duration(days: 7));

    final newFlight = Flight(
      city: widget.destination.city,
      route: flightOffer.displayRoute,
      flightNumber: firstSegment.flight,
      status: 'Scheduled',
      airline: AirlineService.getAirlineName(
        firstSegment.flight.substring(0, 2),
      ),
      departureTime: firstSegment.departure,
      arrivalTime: firstSegment.arrival,
      duration: firstSegment.durationFormatted,
      aircraft: firstSegment.aircraft,
      origin: firstSegment.origin,
      destination: firstSegment.destination,
      flightDate: departureDate,
    );

    await flightManager.addUserFlight(newFlight);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ ${AirlineService.getAirlineName(firstSegment.flight.substring(0, 2))} ${firstSegment.flight} added to trips!',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    MainScreen.mainScreenKey.currentState?.navigateToTab(2);
  }
}

class FlightResultCard extends StatelessWidget {
  final FlightOffer flightOffer; // Changed from RihlaFlightData
  final Airport origin;
  final Airport destination;
  final DateTime? departureDate;
  final VoidCallback onTap;

  const FlightResultCard({
    super.key,
    required this.flightOffer, // Changed parameter name
    required this.origin,
    required this.destination,
    this.departureDate,
    required this.onTap,
  });

  String formatTime(String time24) {
    try {
      final parts = time24.split(':');
      if (parts.length != 2) return time24;

      int hour = int.parse(parts[0]);
      int minute = int.parse(parts[1]);

      String period = hour >= 12 ? 'PM' : 'AM';
      hour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);

      return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
    } catch (e) {
      return time24;
    }
  }

  // Check if arrival is on next day
  bool _isArrivalNextDay() {
    try {
      if (flightOffer.segments.isEmpty) return false;

      final firstSegment = flightOffer.segments.first;
      final lastSegment = flightOffer.segments.last;

      // Parse departure date/time
      final departureStr =
          "${firstSegment.date.year.toString().padLeft(4, '0')}-${firstSegment.date.month.toString().padLeft(2, '0')}-${firstSegment.date.day.toString().padLeft(2, '0')}";
      final departureDateTime = DateTime.parse(
        '$departureStr ${firstSegment.departure}:00',
      );

      // Parse arrival date/time
      final arrivalStr =
          "${lastSegment.date.year.toString().padLeft(4, '0')}-${lastSegment.date.month.toString().padLeft(2, '0')}-${lastSegment.date.day.toString().padLeft(2, '0')}";
      var arrivalDateTime = DateTime.parse(
        '$arrivalStr ${lastSegment.arrival}:00',
      );

      // If arrival time is earlier than departure time, it's next day
      if (arrivalDateTime.isBefore(departureDateTime)) {
        arrivalDateTime = arrivalDateTime.add(const Duration(days: 1));
      }

      // Check if arrival is on a different calendar day
      return arrivalDateTime.day != departureDateTime.day;
    } catch (e) {
      return false;
    }
  }

  // Responsive font sizes based on screen width
  double _getTimeFontSize(double screenWidth) {
    if (screenWidth < 350) return 14.0; // Very small phones
    if (screenWidth < 400) return 16.0; // Small phones
    if (screenWidth < 500) return 18.0; // Medium phones
    if (screenWidth < 600) return 20.0; // Large phones/tablets
    return 22.0; // Tablets/desktop
  }

  double _getLabelFontSize(double screenWidth) {
    if (screenWidth < 350) return 10.0;
    if (screenWidth < 400) return 11.0;
    if (screenWidth < 500) return 12.0;
    if (screenWidth < 600) return 13.0;
    return 14.0;
  }

  double _getAircraftMaxWidth(double screenWidth) {
    if (screenWidth < 350) return 60.0;
    if (screenWidth < 400) return 70.0;
    if (screenWidth < 500) return 80.0;
    return 90.0;
  }

  @override
  Widget build(BuildContext context) {
    // Get airline info from first segment
    final firstSegment = flightOffer.segments.first;
    final airlineCode = firstSegment.flight.length >= 2
        ? firstSegment.flight.substring(0, 2)
        : '';
    final airlineName = AirlineService.getAirlineName(airlineCode);
    final airlineLogoUrl = AirlineService.getAirlineLogoUrl(airlineCode);

    // Show departure date if available
    String dateInfo = '';
    if (departureDate != null) {
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      dateInfo = ' • ${departureDate!.day} ${months[departureDate!.month - 1]}';
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isSmallScreen = screenWidth < 400;
        final isVerySmallScreen = screenWidth < 350;
        final isTablet = screenWidth >= 600;

        final timeFontSize = _getTimeFontSize(screenWidth);
        final labelFontSize = _getLabelFontSize(screenWidth);
        final aircraftMaxWidth = _getAircraftMaxWidth(screenWidth);

        return Container(
          constraints: BoxConstraints(
            minWidth: 0,
            maxWidth:
                MediaQuery.of(context).size.width - 40, // Account for padding
          ),
          margin: const EdgeInsets.only(bottom: 16),
          child: Material(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white,
            elevation: 2,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: EdgeInsets.all(isSmallScreen ? 12.0 : 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Airline Header - Responsive
                    Row(
                      children: [
                        // Airline Logo - Responsive size
                        Container(
                          width: isVerySmallScreen
                              ? 44
                              : (isSmallScreen ? 48 : 56),
                          height: isVerySmallScreen
                              ? 44
                              : (isSmallScreen ? 48 : 56),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(
                              isSmallScreen ? 8 : 12,
                            ),
                            border: Border.all(
                              color: Colors.grey.shade200,
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              isSmallScreen ? 8 : 12,
                            ),
                            child: Image.network(
                              airlineLogoUrl,
                              fit: BoxFit.contain,
                              loadingBuilder:
                                  (context, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return Center(
                                      child: CircularProgressIndicator(
                                        value:
                                            loadingProgress
                                                    .expectedTotalBytes !=
                                                null
                                            ? loadingProgress
                                                      .cumulativeBytesLoaded /
                                                  loadingProgress
                                                      .expectedTotalBytes!
                                            : null,
                                        strokeWidth: 2,
                                        color: const Color(0xFF1E90FF),
                                      ),
                                    );
                                  },
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: const Color(
                                    0xFF1E90FF,
                                  ).withOpacity(0.1),
                                  child: Center(
                                    child: Text(
                                      airlineCode.length >= 2
                                          ? airlineCode
                                                .substring(0, 2)
                                                .toUpperCase()
                                          : '✈️',
                                      style: TextStyle(
                                        color: const Color(0xFF1E90FF),
                                        fontSize: isVerySmallScreen ? 12 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        SizedBox(width: isVerySmallScreen ? 8 : 12),

                        // Airline name and flight number - Responsive
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                airlineName,
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: isVerySmallScreen
                                      ? 14
                                      : (isSmallScreen ? 15 : 16),
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${firstSegment.flight}$dateInfo',
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: isVerySmallScreen
                                      ? 11
                                      : (isSmallScreen ? 12 : 14),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),

                        // Aircraft type - Responsive
                        Container(
                          constraints: BoxConstraints(
                            maxWidth: aircraftMaxWidth,
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: isVerySmallScreen ? 6 : 8,
                            vertical: isVerySmallScreen ? 3 : 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(
                              isSmallScreen ? 3 : 4,
                            ),
                          ),
                          child: Text(
                            firstSegment.aircraft,
                            style: TextStyle(
                              color: const Color(0xFF4CAF50),
                              fontSize: isVerySmallScreen
                                  ? 10
                                  : (isSmallScreen ? 11 : 12),
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isSmallScreen ? 12 : 20),

                    // Show connecting flight info if multi-leg
                    if (flightOffer.segments.length > 1) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.connecting_airports,
                              size: 14,
                              color: Colors.orange.shade700,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${flightOffer.segments.length - 1} stop${flightOffer.segments.length > 2 ? 's' : ''}',
                              style: TextStyle(
                                color: Colors.orange.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'via ${flightOffer.segments.map((s) => s.destination).take(flightOffer.segments.length - 1).join(' → ')}',
                                style: TextStyle(
                                  color: Colors.orange.shade600,
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 12 : 16),
                    ],

                    // Flight Times - Fully Responsive Layout
                    _buildFlightTimesSection(
                      context,
                      screenWidth,
                      timeFontSize,
                      labelFontSize,
                      isSmallScreen,
                      isVerySmallScreen,
                      isTablet,
                    ),

                    SizedBox(height: isSmallScreen ? 12 : 16),
                    Divider(height: 1, color: Colors.grey.shade300),
                    SizedBox(height: isSmallScreen ? 8 : 12),

                    // Action button - Responsive
                    _buildActionButton(
                      context,
                      isSmallScreen,
                      isVerySmallScreen,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFlightTimesSection(
    BuildContext context,
    double screenWidth,
    double timeFontSize,
    double labelFontSize,
    bool isSmallScreen,
    bool isVerySmallScreen,
    bool isTablet,
  ) {
    // Get first and last segments
    final firstSegment = flightOffer.segments.first;
    final lastSegment = flightOffer.segments.last;

    // Format times with AM/PM
    final departureTime = formatTime(firstSegment.departure);
    final arrivalTime = formatTime(lastSegment.arrival);

    // Check if arrival is on next day
    final arrivalNextDay = _isArrivalNextDay();

    // Choose layout based on screen size
    if (isVerySmallScreen) {
      return _buildCompactFlightTimes(
        departureTime,
        arrivalTime,
        arrivalNextDay,
        timeFontSize,
        labelFontSize,
        isVerySmallScreen,
      );
    } else if (isSmallScreen) {
      return _buildSmallFlightTimes(
        departureTime,
        arrivalTime,
        arrivalNextDay,
        timeFontSize,
        labelFontSize,
      );
    } else {
      return _buildRegularFlightTimes(
        context,
        screenWidth,
        departureTime,
        arrivalTime,
        arrivalNextDay,
        timeFontSize,
        labelFontSize,
        isTablet,
      );
    }
  }

  Widget _buildCompactFlightTimes(
    String departureTime,
    String arrivalTime,
    bool arrivalNextDay,
    double timeFontSize,
    double labelFontSize,
    bool isVerySmallScreen,
  ) {
    return Column(
      children: [
        // Top row: Times only
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  departureTime,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: timeFontSize - 2,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  flightOffer.segments.first.origin,
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: labelFontSize - 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),

            // Duration in middle
            Column(
              children: [
                Icon(
                  Icons.flight_takeoff,
                  color:
                      flightOffer.segments.first.flight.contains('QR') ||
                          flightOffer.segments.first.flight.contains('EY')
                      ? const Color(0xFF800000)
                      : const Color(0xFF1E90FF),
                  size: 14,
                ),
                const SizedBox(height: 2),
                Text(
                  flightOffer
                      .displayDurationForCard, // CHANGED from flightOffer.displayDuration
                  style: TextStyle(
                    color: flightOffer.isMultiLeg
                        ? Colors.orange.shade700
                        : Colors.black54,
                    fontSize: labelFontSize - 1,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),

            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    Text(
                      arrivalTime,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: timeFontSize - 2,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (arrivalNextDay) ...[
                      const SizedBox(width: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          '+1',
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  flightOffer.segments.last.destination,
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: labelFontSize - 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),

        // Bottom row: Labels
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Departure',
              style: TextStyle(
                color: Colors.black38,
                fontSize: labelFontSize - 2,
              ),
            ),
            Text(
              'Arrival',
              style: TextStyle(
                color: Colors.black38,
                fontSize: labelFontSize - 2,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSmallFlightTimes(
    String departureTime,
    String arrivalTime,
    bool arrivalNextDay,
    double timeFontSize,
    double labelFontSize,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Departure
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                departureTime,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: timeFontSize,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '${flightOffer.segments.first.origin} • Departure',
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: labelFontSize,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        // Duration
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              Icon(
                Icons.flight_takeoff,
                color:
                    flightOffer.segments.first.flight.contains('QR') ||
                        flightOffer.segments.first.flight.contains('EY')
                    ? const Color(0xFF800000)
                    : const Color(0xFF1E90FF),
                size: 16,
              ),
              const SizedBox(height: 4),
              Text(
                flightOffer
                    .displayDurationForCard, // CHANGED from flightOffer.displayDuration
                style: TextStyle(
                  color: flightOffer.isMultiLeg
                      ? Colors.orange.shade700
                      : Colors.black54,
                  fontSize: labelFontSize,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        // Arrival
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    arrivalTime,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: timeFontSize,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (arrivalNextDay) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '+1',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${flightOffer.segments.last.destination} • Arrival',
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: labelFontSize,
                ),
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // In the FlightResultCard class, update the _buildFlightTimesSection method to show connecting flight details
  // Replace the _buildRegularFlightTimes method with this improved version:

  // Update the _buildRegularFlightTimes method
  Widget _buildRegularFlightTimes(
    BuildContext context,
    double screenWidth,
    String departureTime,
    String arrivalTime,
    bool arrivalNextDay,
    double timeFontSize,
    double labelFontSize,
    bool isTablet,
  ) {
    final columnWidth = isTablet ? screenWidth * 0.25 : screenWidth * 0.28;

    // For connecting flights, show simplified view
    if (flightOffer.segments.length > 1) {
      final firstSegment = flightOffer.segments.first;
      final lastSegment = flightOffer.segments.last;
      final stopCount = flightOffer.segments.length - 1;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Simplified connecting flight view
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Departure
              SizedBox(
                width: columnWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatTime(firstSegment.departure),
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: timeFontSize,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      firstSegment.origin,
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: labelFontSize,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Departure',
                      style: TextStyle(
                        color: Colors.black38,
                        fontSize: labelFontSize - 1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Connecting info
              SizedBox(
                width: columnWidth * 0.8,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.flight_takeoff,
                          color: Colors.blue.shade700,
                          size: isTablet ? 18 : 16,
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.circle,
                          color: Colors.orange.shade700,
                          size: 8,
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.flight_land,
                          color: Colors.green.shade700,
                          size: isTablet ? 18 : 16,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$stopCount stop${stopCount > 1 ? 's' : ''}',
                      style: TextStyle(
                        color: Colors.orange.shade700,
                        fontSize: labelFontSize,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'via ${flightOffer.segments[1].origin}',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: labelFontSize - 1,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Arrival
              SizedBox(
                width: columnWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          formatTime(lastSegment.arrival),
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: timeFontSize,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (arrivalNextDay) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '+1',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lastSegment.destination,
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: labelFontSize,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Arrival',
                      style: TextStyle(
                        color: Colors.black38,
                        fontSize: labelFontSize - 1,
                      ),
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Total trip duration
          const SizedBox(height: 12),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule, color: Colors.blue.shade700, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'Total: ${flightOffer.displayDuration}',
                    style: TextStyle(
                      color: Colors.blue.shade700,
                      fontSize: labelFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // For single segment flights, use the original layout
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Departure
        SizedBox(
          width: columnWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                departureTime,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: timeFontSize,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                flightOffer.segments.first.origin,
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: labelFontSize,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Departure',
                style: TextStyle(
                  color: Colors.black38,
                  fontSize: labelFontSize - 1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        // Duration
        SizedBox(
          width: columnWidth * 0.8,
          child: Column(
            children: [
              Icon(
                Icons.flight_takeoff,
                color: Colors.blue.shade700,
                size: isTablet ? 22 : 18,
              ),
              const SizedBox(height: 4),
              Text(
                flightOffer.displayDurationForCard,
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: labelFontSize,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                height: 1,
                color: Colors.black12,
              ),
            ],
          ),
        ),

        // Arrival
        SizedBox(
          width: columnWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    arrivalTime,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: timeFontSize,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (arrivalNextDay) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '+1',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                flightOffer.segments.last.destination,
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: labelFontSize,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Arrival',
                style: TextStyle(
                  color: Colors.black38,
                  fontSize: labelFontSize - 1,
                ),
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Add this method to show connecting segments details
  void _showConnectingSegments(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Flight Itinerary',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.grey.shade600),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${flightOffer.segments.length} segment${flightOffer.segments.length > 1 ? 's' : ''}:',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              ...flightOffer.segments.asMap().entries.map((entry) {
                final index = entry.key;
                final segment = entry.value;
                final isLast = index == flightOffer.segments.length - 1;

                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Segment number
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.blue.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Segment details
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  segment.origin,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward,
                                  size: 16,
                                  color: Colors.grey.shade600,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  segment.destination,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Flight ${segment.flight} • ${segment.aircraft}',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.flight_takeoff,
                                  size: 14,
                                  color: Colors.green.shade600,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${segment.departure} → ${segment.arrival}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  segment.durationFormatted,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.orange.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            if (!isLast) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: Colors.orange.shade100,
                                  ),
                                ),
                                child: Text(
                                  'Layover at ${segment.destination}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Close Itinerary'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    bool isSmallScreen,
    bool isVerySmallScreen,
  ) {
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [const Color(0xFF1E90FF), Colors.blue.shade700],
          ),
          borderRadius: BorderRadius.circular(isSmallScreen ? 10 : 12),
          boxShadow: [
            BoxShadow(
              color: Colors.blue.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isSmallScreen ? 10 : 12),
            ),
            padding: EdgeInsets.symmetric(
              vertical: isVerySmallScreen ? 10 : (isSmallScreen ? 12 : 14),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_circle_outline,
                color: Colors.white,
                size: isVerySmallScreen ? 16 : 20,
              ),
              SizedBox(width: isVerySmallScreen ? 6 : 8),
              Text(
                'Add to Trips',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isVerySmallScreen ? 12 : (isSmallScreen ? 13 : 14),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AddFlightScreen extends StatefulWidget {
  final Airport? preSelectedOrigin;

  const AddFlightScreen({super.key, this.preSelectedOrigin});

  @override
  State<AddFlightScreen> createState() => _AddFlightScreenState();
}

class _AddFlightScreenState extends State<AddFlightScreen> {
  Airport? origin;
  Airport? destination;
  DateTime selectedDate = DateTime.now();
  bool _showCalendar = false;

  @override
  void initState() {
    super.initState();
    if (widget.preSelectedOrigin != null) {
      origin = widget.preSelectedOrigin;
    }
  }

  DateTime getTomorrow() {
    return DateTime.now().add(const Duration(days: 1));
  }

  DateTime getThisWeekend() {
    final now = DateTime.now();
    // Calculate days until Saturday
    final daysUntilSaturday = (DateTime.saturday - now.weekday) % 7;
    // If today is Saturday, return next Saturday
    return now.add(
      Duration(days: daysUntilSaturday == 0 ? 7 : daysUntilSaturday),
    );
  }

  void selectAirport(bool isOrigin) async {
    final selectedAirport = await Navigator.push<Airport>(
      context,
      MaterialPageRoute(
        builder: (context) => const AirportSelectionScreen(),
        fullscreenDialog: true,
      ),
    );

    if (selectedAirport != null) {
      setState(() {
        if (isOrigin) {
          origin = selectedAirport;
        } else {
          destination = selectedAirport;
        }
      });
    }
  }

  void swapAirports() {
    setState(() {
      final temp = origin;
      origin = destination;
      destination = temp;
    });
  }

  void searchFlights() {
    if (origin == null || destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select both origin and destination airports'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FlightResultsScreen(
          origin: origin!,
          destination: destination!,
          departureDate: selectedDate,
        ),
      ),
    );
  }

  String _formatSelectedDate() {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekdayIndex = selectedDate.weekday - 1; // Monday=0 in Dart

    return '${days[weekdayIndex]}, ${selectedDate.day} ${months[selectedDate.month - 1]} ${selectedDate.year}';
  }

  // Update the buildAirportSelector method
  Widget buildAirportSelector({required bool isOrigin, Airport? airport}) {
    return SizedBox(
      width: double.infinity,
      child: GestureDetector(
        onTap: () => selectAirport(isOrigin),
        child: Container(
          height: 120, // Reduced from 150
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                isOrigin ? 'Origin' : 'Destination',
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              if (airport != null) ...[
                Flexible(
                  child: Text(
                    airport.city,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E90FF).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        airport.code,
                        style: const TextStyle(
                          color: Color(0xFF1E90FF),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        airport.name,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const Text(
                  'Select Airport',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap to choose',
                  style: TextStyle(color: Colors.black54, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
              const Align(
                alignment: Alignment.centerRight,
                child: Icon(
                  Icons.arrow_drop_down,
                  color: Colors.black54,
                  size: 24,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildDateCard(String label, DateTime date, {String? subtitle}) {
    final isSelected =
        selectedDate.year == date.year &&
        selectedDate.month == date.month &&
        selectedDate.day == date.day;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 100, maxWidth: 120),
      child: GestureDetector(
        onTap: () {
          setState(() {
            selectedDate = date;
            _showCalendar = true;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF1E90FF) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? const Color(0xFF1E90FF) : Colors.grey[300]!,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: isSelected
                        ? Colors.white.withOpacity(0.9)
                        : Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.black, size: 24),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Add Flight',
          style: TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Flight Search',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Find the best flights for your journey',
                style: TextStyle(color: Colors.black54, fontSize: 16),
              ),
              const SizedBox(height: 25),

              LayoutBuilder(
                builder: (context, constraints) {
                  return SizedBox(
                    height:
                        180, // Fixed height to prevent unbounded constraints
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Origin selector - Fixed width instead of Expanded
                        Container(
                          width:
                              constraints.maxWidth *
                              0.42, // 42% of available width
                          child: buildAirportSelector(
                            isOrigin: true,
                            airport: origin,
                          ),
                        ),
                        // Swap button
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 25.0,
                          ),
                          child: GestureDetector(
                            onTap: swapAirports,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFDC64C),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.swap_horiz,
                                color: Colors.black,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                        // Destination selector - Fixed width instead of Expanded
                        Container(
                          width:
                              constraints.maxWidth *
                              0.42, // 42% of available width
                          child: buildAirportSelector(
                            isOrigin: false,
                            airport: destination,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              const SizedBox(height: 30),

              // SELECTED DATE DISPLAY
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today,
                      color: Colors.blue.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Selected Departure Date',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _formatSelectedDate(),
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // QUICK DATE OPTIONS
              const Text(
                'Quick Select',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),

              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  buildDateCard(
                    'Today',
                    DateTime.now(),
                    subtitle: '${DateTime.now().day}/${DateTime.now().month}',
                  ),
                  buildDateCard(
                    'Tomorrow',
                    getTomorrow(),
                    subtitle: '${getTomorrow().day}/${getTomorrow().month}',
                  ),
                  buildDateCard(
                    'Weekend',
                    getThisWeekend(),
                    subtitle:
                        '${getThisWeekend().day}/${getThisWeekend().month}',
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // CALENDAR TOGGLE BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _showCalendar = !_showCalendar;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _showCalendar
                        ? Colors.blue.shade50
                        : Colors.grey.shade100,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _showCalendar
                            ? Colors.blue.shade600
                            : Colors.grey.shade300,
                        width: _showCalendar ? 2 : 1,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  icon: Icon(
                    _showCalendar ? Icons.expand_less : Icons.calendar_month,
                    color: _showCalendar
                        ? Colors.blue.shade600
                        : Colors.grey.shade700,
                    size: 22,
                  ),
                  label: Text(
                    _showCalendar ? 'Hide Calendar' : 'Open Calendar',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: _showCalendar
                          ? Colors.blue.shade700
                          : Colors.black,
                    ),
                  ),
                ),
              ),

              // CALENDAR (CONDITIONAL)
              if (_showCalendar) ...[
                const SizedBox(height: 20),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: ColorScheme.light(
                        primary: const Color(0xFF1E90FF),
                        onPrimary: Colors.white,
                        surface: Colors.white,
                        onSurface: Colors.black,
                      ),
                    ),
                    child: CalendarDatePicker(
                      initialDate: selectedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                      onDateChanged: (date) {
                        setState(() {
                          selectedDate = date;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Clear selection button
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        selectedDate = DateTime.now();
                      });
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reset to Today'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey.shade700,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // SEARCH BUTTON - FIXED: Add keyboard padding
              Container(
                width: double.infinity,
                height: 55,
                margin: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 20 : 0,
                ),
                decoration: BoxDecoration(
                  gradient: origin != null && destination != null
                      ? LinearGradient(
                          colors: [
                            const Color(0xFF1E90FF),
                            Colors.blue.shade700,
                          ],
                        )
                      : LinearGradient(
                          colors: [Colors.grey.shade400, Colors.grey.shade500],
                        ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: (origin != null && destination != null)
                          ? Colors.blue.withOpacity(0.3)
                          : Colors.grey.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: TextButton(
                  onPressed: origin != null && destination != null
                      ? searchFlights
                      : null,
                  style: TextButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Search Flights',
                    style: TextStyle(
                      color: origin != null && destination != null
                          ? Colors.white
                          : Colors.grey.shade200,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              // Add extra padding when keyboard is open
              SizedBox(
                height: MediaQuery.of(context).viewInsets.bottom > 0 ? 20 : 0,
              ),

              // Info text
              if (origin != null && destination != null)
                Container(
                  margin: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom > 0
                        ? 20
                        : 0,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Colors.blue.shade700,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Searching for flights from ${origin!.code} to ${destination!.code} on ${_formatSelectedDate()}',
                          style: TextStyle(
                            color: Colors.blue.shade800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AirportSelectionScreen extends StatefulWidget {
  const AirportSelectionScreen({super.key});

  @override
  State<AirportSelectionScreen> createState() => _AirportSelectionScreenState();
}

class _AirportSelectionScreenState extends State<AirportSelectionScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Airport> _filteredAirports = [];
  List<Airport> _displayedAirports = [];
  final ScrollController _scrollController = ScrollController();
  int _currentPage = 0;
  final int _itemsPerPage = 20;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterAirports);
    _filteredAirports = dummyAirports;
    _loadMoreItems();

    // Add scroll listener for pagination
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterAirports);
    _searchController.dispose();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      _loadMoreItems();
    }
  }

  void _loadMoreItems() {
    if (_isLoadingMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    final startIndex = _currentPage * _itemsPerPage;
    final endIndex = startIndex + _itemsPerPage;

    if (startIndex < _filteredAirports.length) {
      final newItems = _filteredAirports.sublist(
        startIndex,
        endIndex > _filteredAirports.length
            ? _filteredAirports.length
            : endIndex,
      );

      setState(() {
        _displayedAirports.addAll(newItems);
        _currentPage++;
        _isLoadingMore = false;
      });
    } else {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  void _filterAirports() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredAirports = dummyAirports;
      } else {
        _filteredAirports = dummyAirports.where((airport) {
          return airport.name.toLowerCase().contains(query) ||
              airport.city.toLowerCase().contains(query) ||
              airport.code.toLowerCase().contains(query);
        }).toList();
      }

      // Reset pagination
      _displayedAirports.clear();
      _currentPage = 0;
      _loadMoreItems();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF1E90FF)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Select Airport',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(15.0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText:
                      'Search by airport, city, or code (e.g., Dubai or DXB)',
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            _filterAirports();
                          },
                        )
                      : null,
                ),
                style: const TextStyle(color: Colors.black),
                onChanged: (value) {
                  // Debounce search
                  Future.delayed(const Duration(milliseconds: 300), () {
                    if (mounted) _filterAirports();
                  });
                },
              ),
            ),

            // Show search count
            if (_searchController.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Text(
                      '${_filteredAirports.length} airports found',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            Expanded(
              child: _displayedAirports.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.airplanemode_inactive,
                            size: 60,
                            color: Colors.grey[300],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No airports found',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                          if (_searchController.text.isNotEmpty)
                            const SizedBox(height: 8),
                          if (_searchController.text.isNotEmpty)
                            const Text(
                              'Try a different search term',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount:
                          _displayedAirports.length + (_isLoadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _displayedAirports.length) {
                          return _buildLoadingIndicator();
                        }
                        final airport = _displayedAirports[index];
                        return _buildAirportListItem(airport, context);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: CircularProgressIndicator(
          color: Color(0xFF1E90FF),
          strokeWidth: 2,
        ),
      ),
    );
  }

  Widget _buildAirportListItem(Airport airport, BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 0,
        maxWidth: MediaQuery.of(context).size.width,
      ),
      child: Material(
        color: Colors.white,
        child: InkWell(
          onTap: () {
            Navigator.of(context).pop(airport);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E90FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      airport.code,
                      style: const TextStyle(
                        color: Color(0xFF1E90FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        airport.city,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.black,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        airport.name,
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// DESTINATION CARD
class DestinationCard extends StatelessWidget {
  final Destination destination;

  const DestinationCard({super.key, required this.destination});

  @override
  Widget build(BuildContext context) {
    // Extract airport code from destination title
    String airportCode = _extractAirportCode(destination.title);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AirportDetailsScreen(
              airportCode: airportCode,
              airportName: destination.title.split(',').first,
              gradientStart: const Color(0xFF8B0000),
              gradientEnd: const Color(0xFFFFD700),
            ),
          ),
        );
      },
      child: Container(
        width: 300,
        margin: const EdgeInsets.only(left: 20, right: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF161F34),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Background Image - ONLY FROM API
            Positioned.fill(child: _buildApiImage()),

            // Gradient Overlay
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                  ),
                ),
              ),
            ),

            // Title - FIXED WITH OVERFLOW PROTECTION
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        destination.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(
                              color: Colors.black45,
                              offset: Offset(0, 1),
                              blurRadius: 3,
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.explore,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'From $airportCode',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _extractAirportCode(String title) {
    // Try to extract airport code from known destinations
    final airportMap = {
      'Dubai': 'DXB',
      'Belgrade': 'BEG',
      'Sri Lanka': 'CMB', // Colombo
      'Kuala Lumpur': 'KUL',
      'Algiers': 'ALG',
      'Almaty': 'ALA',
      'Bahrain': 'BAH', // Bahrain International
      'Santorini': 'JTR',
      'Baku': 'GYD',
      'Athens': 'ATH',
      'Riyadh': 'RUH',
      'Jeddah': 'JED',
      'Istanbul': 'IST',
      'Doha': 'DOH',
      'Abu Dhabi': 'AUH',
      'Sharjah': 'SHJ',
      'Medina': 'MED',
    };

    for (final city in airportMap.keys) {
      if (title.contains(city)) {
        return airportMap[city]!;
      }
    }

    // Default to first 3 letters of city name
    final cityName = title.split(',').first;
    if (cityName.length >= 3) {
      return cityName.substring(0, 3).toUpperCase();
    }

    return 'XXX';
  }

  Widget _buildApiImage() {
    // Validate API image URL
    if (destination.imageUrl.isEmpty ||
        !destination.imageUrl.startsWith('http') ||
        destination.imageUrl.contains('undefined')) {
      return _buildApiPlaceholder();
    }

    return Image.network(
      destination.imageUrl,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: const Color(0xFF161F34),
          child: const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFFDC64C),
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        print('❌ API Image failed for ${destination.title}: $error');
        return _buildApiPlaceholder();
      },
    );
  }

  Widget _buildApiPlaceholder() {
    // Use city name or destination title for placeholder
    final cityName = destination.title.split(',').first;
    return Container(
      color: const Color(0xFF1E90FF).withOpacity(0.2),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.airplanemode_active,
              color: Colors.white.withOpacity(0.7),
              size: 50,
            ),
            const SizedBox(height: 10),
            Text(
              cityName,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getAirportCode(String title) {
    final airportMap = {
      'Dubai': 'DXB',
      'Belgrade': 'BEG',
      'Sri Lanka': 'CMB',
      'Kuala Lumpur': 'KUL',
      'Algiers': 'ALG',
      'Almaty': 'ALA',
      'Bahrain': 'BAH',
      'Santorini': 'JTR',
    };

    for (final city in airportMap.keys) {
      if (title.contains(city)) {
        return airportMap[city]!;
      }
    }
    return 'API';
  }
}

// DEAL GRID ITEM
class DealGridItem extends StatelessWidget {
  final Deal deal;

  const DealGridItem({super.key, required this.deal});

  @override
  Widget build(BuildContext context) {
    // Extract airport code from deal name
    String airportCode = _extractAirportCode(deal.name);
    String cityName = deal.name.split(' ').first;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AirportDetailsScreen(
              airportCode: airportCode,
              airportName: cityName,
              gradientStart: const Color(0xFF4CAF50),
              gradientEnd: const Color(0xFF2196F3),
            ),
          ),
        );
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 180, maxHeight: 220),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xFF161F34),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Image Section
            Expanded(flex: 3, child: _buildDealImage()),

            // Title Section - FIXED WITH CONSTRAINTS
            Container(
              constraints: const BoxConstraints(minHeight: 70, maxHeight: 90),
              padding: const EdgeInsets.all(12),
              color: const Color(0xFF161F34),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      deal.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.local_offer,
                        color: Colors.orange.shade400,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '$airportCode Airport • Special Deal',
                          style: TextStyle(
                            color: Colors.orange.shade400,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _extractAirportCode(String dealName) {
    // Extract airport code from deal names
    final airportMap = {
      'Dubai': 'DXB',
      'Santorini': 'JTR',
      'Baku': 'GYD',
      'Athens': 'ATH',
      'Istanbul': 'IST',
      'Doha': 'DOH',
      'Abu Dhabi': 'AUH',
      'Sharjah': 'SHJ',
      'Bahrain': 'BAH',
      'Riyadh': 'RUH',
      'Jeddah': 'JED',
      'Medina': 'MED',
      'Kuala Lumpur': 'KUL',
      'Almaty': 'ALA',
      'Algiers': 'ALG',
    };

    for (final city in airportMap.keys) {
      if (dealName.contains(city)) {
        return airportMap[city]!;
      }
    }

    // Default to first 3 letters of first word
    final firstWord = dealName.split(' ').first;
    if (firstWord.length >= 3) {
      return firstWord.substring(0, 3).toUpperCase();
    }

    return 'FLY';
  }

  Widget _buildDealImage() {
    // Validate API image URL
    if (deal.imageUrl.isEmpty ||
        !deal.imageUrl.startsWith('http') ||
        deal.imageUrl.contains('undefined')) {
      return _buildDealPlaceholder();
    }

    return Image.network(
      deal.imageUrl,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: const Color(0xFF161F34),
          child: const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFFDC64C),
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        print('❌ Deal API Image failed for ${deal.name}: $error');
        return _buildDealPlaceholder();
      },
    );
  }

  Widget _buildDealPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.orange.shade800.withOpacity(0.3),
            Colors.orange.shade600.withOpacity(0.3),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_offer, color: Colors.orange.shade300, size: 40),
            const SizedBox(height: 8),
            Text(
              'Special Offer',
              style: TextStyle(
                color: Colors.orange.shade200,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// DESTINATION DETAIL SCREEN
class DestinationDetailScreen extends StatelessWidget with ResponsiveMixin {
  final Destination destination;

  const DestinationDetailScreen({super.key, required this.destination});

  String get iataCode {
    if (destination.title.contains('Santorini')) return 'JTR';
    if (destination.title.contains('Dubai')) return 'DXB';
    if (destination.title.contains('Belgrade')) return 'BEG';
    if (destination.title.contains('Sri Lanka')) return 'CMB';
    if (destination.title.contains('Kuala Lumpur')) return 'KUL';
    if (destination.title.contains('Algiers')) return 'ALG';
    if (destination.title.contains('Almaty')) return 'ALA';
    if (destination.title.contains('Bahrain')) return 'BAH';
    return 'XXX';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            color: Color(0xFF1E90FF),
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${destination.title} ($iataCode)',
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(
          responsiveValue(context, mobile: 16, tablet: 24, desktop: 32),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Destination Details',
              style: TextStyle(
                fontSize: responsiveValue(
                  context,
                  mobile: 24,
                  tablet: 28,
                  desktop: 32,
                ),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Explore amazing flights to ${destination.title}',
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

// DEAL DETAIL SCREEN
class DealDetailScreen extends StatelessWidget with ResponsiveMixin {
  final Deal deal;

  const DealDetailScreen({super.key, required this.deal});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            color: Color(0xFF1E90FF),
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          deal.name,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(
          responsiveValue(context, mobile: 16, tablet: 24, desktop: 32),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Deal Details',
              style: TextStyle(
                fontSize: responsiveValue(
                  context,
                  mobile: 24,
                  tablet: 28,
                  desktop: 32,
                ),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Special offer: ${deal.name}',
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 1. LANGUAGE SCREEN ---
class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  final LanguagePreferences prefs = LanguagePreferences();

  String getCurrentLanguageCode(BuildContext context) {
    return context.locale.languageCode;
  }

  @override
  Widget build(BuildContext context) {
    final currentCode = getCurrentLanguageCode(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        title: Text('select_language'.tr()),
        backgroundColor: const Color(0xFF0C1324),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: prefs.supportedLanguages.length,
        itemBuilder: (context, index) {
          final lang = prefs.supportedLanguages[index];
          final isSelected = lang['code'] == currentCode;

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFFFDC64C).withOpacity(0.1)
                  : const Color(0xFF161F34),
              borderRadius: BorderRadius.circular(12),
              border: isSelected
                  ? Border.all(color: const Color(0xFFFDC64C), width: 2)
                  : null,
            ),
            child: ListTile(
              onTap: () async {
                // ✅ Set the locale for EasyLocalization
                await context.setLocale(Locale(lang['code']!));

                // ✅ Update preference
                prefs.setLanguage(lang['name']!);

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('language_changed'.tr()),
                      backgroundColor: const Color(0xFFFDC64C),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );

                  // ✅ Pop back to trigger rebuild
                  Navigator.pop(context);
                }
              },
              leading: Text(
                lang['flag']!,
                style: const TextStyle(fontSize: 28),
              ),
              title: Text(
                lang['name']!,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 16,
                ),
              ),
              trailing: isSelected
                  ? const Icon(
                      Icons.check_circle,
                      color: Color(0xFFFDC64C),
                      size: 24,
                    )
                  : const Icon(
                      Icons.circle_outlined,
                      color: Colors.white30,
                      size: 24,
                    ),
            ),
          );
        },
      ),
    );
  }
}

// --- 2. NOTIFICATIONS SCREEN ---
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  bool _pushEnabled = true;
  bool _emailEnabled = true;
  bool _promosEnabled = false;

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161F34),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        value: value,
        activeColor: const Color(0xFFFDC64C),
        onChanged: onChanged,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF0C1324),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSwitchTile(
            'Push Notifications',
            'Receive real-time updates about your flights and gate changes.',
            _pushEnabled,
            (v) => setState(() => _pushEnabled = v),
          ),
          _buildSwitchTile(
            'Email Alerts',
            'Get booking confirmations and itinerary summaries.',
            _emailEnabled,
            (v) => setState(() => _emailEnabled = v),
          ),
          _buildSwitchTile(
            'Promotions & Deals',
            'Be the first to know about price drops and special offers.',
            _promosEnabled,
            (v) => setState(() => _promosEnabled = v),
          ),
        ],
      ),
    );
  }
}

// --- 3. PRIVACY & SECURITY SCREEN ---
class PrivacySecurityScreen extends StatelessWidget {
  const PrivacySecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        title: const Text(
          'Privacy & Security',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF0C1324),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ListTile(
            leading: const Icon(Icons.lock_outline, color: Colors.white),
            title: const Text(
              'Change Password',
              style: TextStyle(color: Colors.white),
            ),
            trailing: const Icon(
              Icons.arrow_forward_ios,
              color: Colors.white30,
              size: 16,
            ),
            onTap: () {},
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: const Color(0xFF161F34),
          ),
          const SizedBox(height: 10),
          ListTile(
            leading: const Icon(Icons.fingerprint, color: Colors.white),
            title: const Text(
              'Biometric Login',
              style: TextStyle(color: Colors.white),
            ),
            trailing: Switch(
              value: true,
              onChanged: (v) {},
              activeColor: const Color(0xFFFDC64C),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: const Color(0xFF161F34),
          ),
          const SizedBox(height: 30),
          const Text(
            'DATA MANAGEMENT',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text(
              'Delete Account',
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  backgroundColor: const Color(0xFF161F34),
                  title: const Text(
                    'Delete Account?',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: const Text(
                    'This action cannot be undone. All your trips and data will be lost.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: const Color(0xFF161F34),
          ),
        ],
      ),
    );
  }
}

// --- 4. HELP & SUPPORT SCREEN ---
class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        title: const Text(
          'Help & Support',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF0C1324),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFDC64C), Color(0xFFFFA726)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Need instant help?',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Start a live chat with our support team.',
                        style: TextStyle(color: Colors.black87),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'FREQUENTLY ASKED QUESTIONS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          _buildFaqItem(
            'How do I change my flight?',
            'You can request a change directly from the "Trips" tab by selecting your active flight.',
          ),
          _buildFaqItem(
            'What is the refund policy?',
            'Refunds depend on the airline carrier. Standard Rihla bookings are refundable within 24 hours.',
          ),
          _buildFaqItem(
            'Do you support multi-city booking?',
            'Currently we support round-trip and one-way. Multi-city is coming in v2.0.',
          ),
        ],
      ),
    );
  }

  Widget _buildFaqItem(String question, String answer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161F34),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        title: Text(
          question,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        iconColor: const Color(0xFFFDC64C),
        collapsedIconColor: Colors.white54,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              answer,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 5. ABOUT SCREEN ---
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.waves, size: 80, color: Color(0xFFFDC64C)),
            const SizedBox(height: 20),
            const Text(
              'Rihla',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const Text(
              'Beyond the Journey',
              style: TextStyle(color: Colors.white54, letterSpacing: 1.2),
            ),
            const SizedBox(height: 40),
            const Text(
              'Version 1.0.0',
              style: TextStyle(color: Colors.white38),
            ),
            const SizedBox(height: 40),
            TextButton(
              onPressed: () {},
              child: const Text(
                'Terms of Service',
                style: TextStyle(color: Color(0xFF1E90FF)),
              ),
            ),
            TextButton(
              onPressed: () {},
              child: const Text(
                'Privacy Policy',
                style: TextStyle(color: Color(0xFF1E90FF)),
              ),
            ),
            TextButton(
              onPressed: () {},
              child: const Text(
                'Open Source Licenses',
                style: TextStyle(color: Color(0xFF1E90FF)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ========== PASTE THIS AT THE END OF YOUR FILE ==========
// Find the SearchResultsScreen class (around line ~9500) and update the build method

class SearchResultsScreen extends StatelessWidget {
  final String query;
  final List<RihlaFlightData>
  results; // This is still RihlaFlightData from search
  final String searchType;

  const SearchResultsScreen({
    super.key,
    required this.query,
    required this.results,
    required this.searchType,
  });

  // Update the build method
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1324),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1324),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              query,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              searchType,
              style: const TextStyle(color: Color(0xFFFDC64C), fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        centerTitle: false,
      ),
      body: Column(
        children: [
          // Stats header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF161F34),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDC64C).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.search,
                    color: Color(0xFFFDC64C),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${results.length} results found',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Search completed successfully',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Results list - FIXED: Use Expanded with ListView
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final flight = results[index];
                final flightOffer = FlightOffer(
                  id: flight.hashCode,
                  segments: [
                    FlightOfferSegment(
                      offerId: flight.hashCode,
                      flight: flight.flightNumber,
                      aircraft: flight.aircraft,
                      ticketingUntil: DateTime.now()
                          .add(const Duration(days: 1))
                          .toIso8601String()
                          .split('T')[0],
                      price: 0.0,
                      pricePkr: 0,
                      date: DateTime.now(),
                      origin: flight.origin,
                      departure: flight.departureTime,
                      destination: flight.destination,
                      arrival: flight.arrivalTime,
                      checkedBag: BaggageInfo(
                        weight: 0,
                        weightUnit: 'KG',
                        quantity: 0,
                      ),
                      duration: _parseDurationToMinutes(flight.duration),
                      durationFormatted: flight.duration,
                      compositeScore: 0.0,
                      rank: 1,
                    ),
                  ],
                  totalPrice: 0.0,
                  totalPricePkr: 0,
                  rank: 1,
                  compositeScore: 0.0,
                  totalTripDuration: flight.duration,
                );

                final originAirport = Airport(
                  name: flight.origin,
                  code: flight.origin,
                  city: flight.origin,
                  country: '',
                );

                final destinationAirport = Airport(
                  name: flight.destination,
                  code: flight.destination,
                  city: flight.destination,
                  country: '',
                );

                return FlightResultCard(
                  flightOffer: flightOffer,
                  origin: originAirport,
                  destination: destinationAirport,
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) =>
                          FlightDetailsBottomSheet(flight: flight),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to parse duration string to minutes
  int _parseDurationToMinutes(String durationStr) {
    try {
      // Handle formats like "3h 15min", "03:35", "3hr 15min"
      if (durationStr.contains('h') || durationStr.contains('hr')) {
        final hoursMatch = RegExp(r'(\d+)\s*h').firstMatch(durationStr);
        final minsMatch = RegExp(r'(\d+)\s*min').firstMatch(durationStr);

        int hours = hoursMatch != null ? int.parse(hoursMatch.group(1)!) : 0;
        int minutes = minsMatch != null ? int.parse(minsMatch.group(1)!) : 0;

        return hours * 60 + minutes;
      } else if (durationStr.contains(':')) {
        final parts = durationStr.split(':');
        if (parts.length == 2) {
          return int.parse(parts[0]) * 60 + int.parse(parts[1]);
        }
      }
    } catch (e) {
      print('Error parsing duration: $e');
    }
    return 0;
  }
}

// ========== AIRPORT DETAILS SCREEN ==========
class AirportDetailsScreen extends StatefulWidget {
  final String airportCode;
  final String airportName;
  final Color? gradientStart;
  final Color? gradientEnd;

  const AirportDetailsScreen({
    super.key,
    required this.airportCode,
    required this.airportName,
    this.gradientStart,
    this.gradientEnd,
  });

  @override
  State<AirportDetailsScreen> createState() => _AirportDetailsScreenState();
}

class _AirportDetailsScreenState extends State<AirportDetailsScreen> {
  List<RihlaFlightData> _departingFlights = [];
  List<RihlaFlightData> _arrivingFlights = [];
  Map<String, dynamic> _airportStats = {
    'airlines': 0,
    'departingRoutes': 0,
    'arrivingRoutes': 0,
  };
  bool _isLoading = true;
  bool _isLoadingRoutes = true;
  List<String> _popularRoutes = [];

  @override
  void initState() {
    super.initState();
    _loadAirportData();
    _loadPopularRoutes();
  }

  Future<void> _loadAirportData() async {
    setState(() => _isLoading = true);

    try {
      // Load flights for this airport
      final flights = await RihlaApiService.fetchFlightsByAirport(
        widget.airportCode,
      );

      if (flights.isNotEmpty) {
        // Split into departing and arriving flights
        _departingFlights = flights
            .where(
              (f) => f.origin.toUpperCase() == widget.airportCode.toUpperCase(),
            )
            .toList();

        _arrivingFlights = flights
            .where(
              (f) =>
                  f.destination.toUpperCase() ==
                  widget.airportCode.toUpperCase(),
            )
            .toList();

        // Calculate stats
        final uniqueAirlines = {
          ..._departingFlights.map((f) => f.airline),
          ..._arrivingFlights.map((f) => f.airline),
        }.length;

        final departingRoutes = _departingFlights
            .map((f) => '${f.origin}→${f.destination}')
            .toSet()
            .length;

        final arrivingRoutes = _arrivingFlights
            .map((f) => '${f.origin}→${f.destination}')
            .toSet()
            .length;

        setState(() {
          _airportStats = {
            'airlines': uniqueAirlines,
            'departingRoutes': departingRoutes,
            'arrivingRoutes': arrivingRoutes,
          };
        });
      }

      setState(() => _isLoading = false);
    } catch (e) {
      print('❌ Error loading airport data: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPopularRoutes() async {
    try {
      // Get popular routes from the flights data
      final flights = await RihlaApiService.fetchFlightsByAirport(
        widget.airportCode,
      );

      if (flights.isNotEmpty) {
        // Count route frequencies
        final routeCounts = <String, int>{};

        for (final flight in flights) {
          final routeKey = flight.origin == widget.airportCode
              ? '${widget.airportCode} → ${flight.destination}'
              : '${flight.origin} → ${widget.airportCode}';

          routeCounts[routeKey] = (routeCounts[routeKey] ?? 0) + 1;
        }

        // Sort by frequency and take top 3
        final sortedRoutes = routeCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

        setState(() {
          _popularRoutes = sortedRoutes.take(3).map((e) => e.key).toList();
          _isLoadingRoutes = false;
        });
      } else {
        // Fallback to known popular routes based on airport
        _popularRoutes = _getDefaultPopularRoutes();
        setState(() => _isLoadingRoutes = false);
      }
    } catch (e) {
      print('❌ Error loading popular routes: $e');
      _popularRoutes = _getDefaultPopularRoutes();
      setState(() => _isLoadingRoutes = false);
    }
  }

  List<String> _getDefaultPopularRoutes() {
    // Default popular routes for major airports
    final popularRoutesMap = {
      'DXB': ['DXB → LHR', 'DXB → JFK', 'DXB → SIN'],
      'LHE': ['LHE → DXB', 'LHE → SHJ', 'LHE → ISB'],
      'KHI': ['KHI → DOH', 'KHI → DXB', 'KHI → AUH'],
      'ISB': ['ISB → IST', 'ISB → DXB', 'ISB → JED'],
      'JTR': ['JTR → JED', 'JTR → DXB', 'JTR → IST'], // Santorini
      'DOH': ['DOH → LHR', 'DOH → JFK', 'DOH → SIN'],
      'AUH': ['AUH → LHR', 'AUH → BKK', 'AUH → CMN'],
    };

    return popularRoutesMap[widget.airportCode] ??
        [
          '${widget.airportCode} → DXB',
          '${widget.airportCode} → LHR',
          '${widget.airportCode} → JFK',
        ];
  }

  void _searchFlightsFromThisAirport() {
    // Get airport from dummyAirports
    final airport = dummyAirports.firstWhere(
      (a) => a.code == widget.airportCode,
      orElse: () => Airport(
        name: widget.airportName,
        code: widget.airportCode,
        city: widget.airportName,
        country: '',
      ),
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddFlightScreen(preSelectedOrigin: airport),
      ),
    );
  }

  void _showOnMap() {
    final cityLocation = mapCities[widget.airportCode];
    if (cityLocation != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AirportMapScreen(
            airportCode: widget.airportCode,
            airportName: widget.airportName,
            latitude: cityLocation.lat,
            longitude: cityLocation.lon,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Map location not available for this airport'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _searchRoute(String route) {
    final parts = route.split(' → ');
    if (parts.length == 2) {
      final originCode = parts[0];
      final destinationCode = parts[1];

      final originAirport = dummyAirports.firstWhere(
        (a) => a.code == originCode,
        orElse: () => Airport(
          name: originCode,
          code: originCode,
          city: originCode,
          country: '',
        ),
      );

      final destinationAirport = dummyAirports.firstWhere(
        (a) => a.code == destinationCode,
        orElse: () => Airport(
          name: destinationCode,
          code: destinationCode,
          city: destinationCode,
          country: '',
        ),
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FlightResultsScreen(
            origin: originAirport,
            destination: destinationAirport,
          ),
        ),
      );
    }
  }

  // Helper to get gradient colors based on airport code
  List<Color> _getGradientColors() {
    if (widget.gradientStart != null && widget.gradientEnd != null) {
      return [widget.gradientStart!, widget.gradientEnd!];
    }

    // Default gradients for different regions
    final gradientMap = {
      'DXB': [
        const Color(0xFF0052D4),
        const Color(0xFF4364F7),
      ], // Emirates blue
      'LHE': [
        const Color(0xFF800000),
        const Color(0xFFFFD700),
      ], // Maroon & Gold
      'KHI': [const Color(0xFF006400), const Color(0xFF90EE90)], // Green theme
      'ISB': [const Color(0xFF1E90FF), const Color(0xFF87CEEB)], // Blue theme
      'JTR': [
        const Color(0xFF8B0000),
        const Color(0xFFFFD700),
      ], // Santorini maroon & gold
      'DOH': [
        const Color(0xFF800000),
        const Color(0xFFADD8E6),
      ], // Qatar maroon & light blue
    };

    return gradientMap[widget.airportCode] ??
        [const Color(0xFF0C1324), const Color(0xFFFDC64C)]; // App theme
  }

  @override
  Widget build(BuildContext context) {
    final gradientColors = _getGradientColors();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.blue),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "${widget.airportName} (${widget.airportCode})",
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.blue),
            onPressed: () {
              // Share airport info
              final text =
                  "Check out ${widget.airportName} (${widget.airportCode}) flights on Rihla!";
              // You can integrate a share package here
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Share: $text'),
                  backgroundColor: Colors.green,
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Card with Gradient
            Container(
              height: 160,
              width: double.infinity,
              margin: const EdgeInsets.only(top: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  colors: gradientColors,
                  begin: Alignment.centerLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: gradientColors.first.withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              alignment: Alignment.bottomLeft,
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: "${widget.airportCode} ",
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    TextSpan(
                      text: widget.airportName,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Title and Overview
            Text(
              "${widget.airportName} (${widget.airportCode})",
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const Text(
              "Overview",
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Horizontal Stats/Buttons
            _isLoading
                ? _buildStatsLoading()
                : Row(
                    children: [
                      _buildStatCard(
                        _airportStats['airlines'].toString(),
                        "Airlines",
                        icon: Icons.airlines,
                      ),
                      const SizedBox(width: 10),
                      _buildStatCard(
                        _airportStats['departingRoutes'].toString(),
                        "Departing Routes",
                        icon: Icons.flight_takeoff,
                      ),
                      const SizedBox(width: 10),
                      _buildStatCard(
                        _airportStats['arrivingRoutes'].toString(),
                        "Arriving Routes",
                        icon: Icons.flight_land,
                      ),
                    ],
                  ),
            const SizedBox(height: 24),

            // Popular Routes Section
            const Text(
              "Popular Routes",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 12),
            _isLoadingRoutes
                ? _buildRoutesLoading()
                : Column(
                    children: _popularRoutes
                        .map((route) => _buildRouteItem(route))
                        .toList(),
                  ),

            const SizedBox(height: 24),

            // Quick Actions Section
            const Text(
              "Quick Actions",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 12),
            _buildActionButton(
              Icons.search,
              "Search flights to/from ${widget.airportCode}",
              Colors.blue,
              onTap: _searchFlightsFromThisAirport,
            ),
            const SizedBox(height: 12),
            _buildActionButton(
              Icons.map_outlined,
              "Show on map",
              Colors.blue.shade50,
              textColor: Colors.blue,
              onTap: _showOnMap,
            ),
            const SizedBox(height: 24),

            // Live Flights Section (if available)
            if (_departingFlights.isNotEmpty ||
                _arrivingFlights.isNotEmpty) ...[
              const Text(
                "Live Flights",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 12),
              _buildLiveFlightsPreview(),
              const SizedBox(height: 40),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatsLoading() {
    return Row(
      children: [
        _buildStatCard("-", "Loading...", icon: Icons.hourglass_empty),
        const SizedBox(width: 10),
        _buildStatCard("-", "Loading...", icon: Icons.hourglass_empty),
        const SizedBox(width: 10),
        _buildStatCard("-", "Loading...", icon: Icons.hourglass_empty),
      ],
    );
  }

  Widget _buildRoutesLoading() {
    return Column(
      children: [
        _buildRouteItem("Loading..."),
        _buildRouteItem("Loading..."),
        _buildRouteItem("Loading..."),
      ],
    );
  }

  Widget _buildStatCard(String value, String label, {IconData? icon}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 24, color: Colors.blue),
              const SizedBox(height: 8),
            ],
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteItem(String route) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: const Icon(Icons.flight_takeoff, color: Colors.blue),
        title: Text(
          route,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _searchRoute(route),
      ),
    );
  }

  Widget _buildActionButton(
    IconData icon,
    String label,
    Color bgColor, {
    Color textColor = Colors.white,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: bgColor == Colors.blue.shade50
              ? Border.all(color: Colors.blue.shade100)
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveFlightsPreview() {
    final totalFlights = _departingFlights.length + _arrivingFlights.length;
    final previewFlights = [
      ..._departingFlights.take(2),
      ..._arrivingFlights.take(2),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "$totalFlights flights found",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.wifi, size: 12, color: Colors.green),
                    SizedBox(width: 4),
                    Text(
                      "LIVE",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...previewFlights.map((flight) {
            final isDeparture = flight.origin == widget.airportCode;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isDeparture
                          ? Colors.blue.shade50
                          : Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isDeparture ? Icons.flight_takeoff : Icons.flight_land,
                      size: 16,
                      color: isDeparture ? Colors.blue : Colors.green,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          flight.flightNumber,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                        Text(
                          isDeparture
                              ? 'To ${flight.destination} • ${flight.departureTime}'
                              : 'From ${flight.origin} • ${flight.arrivalTime}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    flight.airline,
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              // Navigate to full flights list
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AirportFlightsScreen(
                    airportCode: widget.airportCode,
                    airportName: widget.airportName,
                  ),
                ),
              );
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue,
              padding: EdgeInsets.zero,
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("View all flights"),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Helper function to extract airport code from any text
String extractAirportCodeFromText(String text) {
  // Check if text contains a known airport code pattern (3 uppercase letters)
  final airportCodeRegex = RegExp(r'\b[A-Z]{3}\b');
  final match = airportCodeRegex.firstMatch(text);
  if (match != null) {
    return match.group(0)!;
  }

  // Check for known city names
  final cityToAirportMap = {
    'dubai': 'DXB',
    'santorini': 'JTR',
    'baku': 'GYD',
    'athens': 'ATH',
    'istanbul': 'IST',
    'doha': 'DOH',
    'abu dhabi': 'AUH',
    'sharjah': 'SHJ',
    'bahrain': 'BAH',
    'riyadh': 'RUH',
    'jeddah': 'JED',
    'medina': 'MED',
    'kuala lumpur': 'KUL',
    'almaty': 'ALA',
    'algiers': 'ALG',
    'belgrade': 'BEG',
    'colombo': 'CMB',
    'lahore': 'LHE',
    'karachi': 'KHI',
    'islamabad': 'ISB',
  };

  final lowerText = text.toLowerCase();
  for (final city in cityToAirportMap.keys) {
    if (lowerText.contains(city)) {
      return cityToAirportMap[city]!;
    }
  }

  // Default: try to get from dummyAirports based on city name
  final matchingAirport = dummyAirports.firstWhere(
    (airport) => text.toLowerCase().contains(airport.city.toLowerCase()),
    orElse: () =>
        Airport(name: 'Unknown', code: 'XXX', city: 'Unknown', country: ''),
  );

  return matchingAirport.code;
}

// ========== AIRPORT MAP SCREEN ==========
class AirportMapScreen extends StatelessWidget {
  final String airportCode;
  final String airportName;
  final double latitude;
  final double longitude;

  const AirportMapScreen({
    super.key,
    required this.airportCode,
    required this.airportName,
    required this.latitude,
    required this.longitude,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.blue),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "$airportName on Map",
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: LatLng(latitude, longitude),
          initialZoom: 12.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c'],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(latitude, longitude),
                width: 100,
                height: 100,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.blue, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.3),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.flight, color: Colors.blue, size: 24),
                      const SizedBox(height: 4),
                      Text(
                        airportCode,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        airportName,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Open in Google Maps or Apple Maps
          final url =
              'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude&query_place_id=$airportName+Airport';
          // You can use url_launcher package here
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Open $airportCode in maps: $url'),
              backgroundColor: Colors.green,
            ),
          );
        },
        backgroundColor: Colors.blue,
        child: const Icon(Icons.open_in_new, color: Colors.white),
      ),
    );
  }
}

// ========== AIRPORT FLIGHTS SCREEN ==========
class AirportFlightsScreen extends StatefulWidget {
  final String airportCode;
  final String airportName;

  const AirportFlightsScreen({
    super.key,
    required this.airportCode,
    required this.airportName,
  });

  @override
  State<AirportFlightsScreen> createState() => _AirportFlightsScreenState();
}

class _AirportFlightsScreenState extends State<AirportFlightsScreen> {
  List<RihlaFlightData> _flights = [];
  bool _isLoading = true;
  String _selectedFilter = 'all'; // 'all', 'departures', 'arrivals'

  @override
  void initState() {
    super.initState();
    _loadFlights();
  }

  Future<void> _loadFlights() async {
    setState(() => _isLoading = true);

    try {
      final flights = await RihlaApiService.fetchFlightsByAirport(
        widget.airportCode,
      );

      setState(() {
        _flights = flights;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Error loading flights: $e');
      setState(() => _isLoading = false);
    }
  }

  List<RihlaFlightData> get _filteredFlights {
    switch (_selectedFilter) {
      case 'departures':
        return _flights.where((f) => f.origin == widget.airportCode).toList();
      case 'arrivals':
        return _flights
            .where((f) => f.destination == widget.airportCode)
            .toList();
      default:
        return _flights;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.blue),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Flights - ${widget.airportCode}",
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Filter chips
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildFilterChip('All', 'all'),
                const SizedBox(width: 8),
                _buildFilterChip('Departures', 'departures'),
                const SizedBox(width: 8),
                _buildFilterChip('Arrivals', 'arrivals'),
              ],
            ),
          ),

          // Flights list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.blue),
                  )
                : _flights.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.flight_takeoff,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'No flights found',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Try again later for ${widget.airportCode}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _filteredFlights.length,
                    itemBuilder: (context, index) {
                      final flight = _filteredFlights[index];
                      final isDeparture = flight.origin == widget.airportCode;

                      return _buildFlightCard(flight, isDeparture);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _selectedFilter == value;

    return GestureDetector(
      onTap: () {
        setState(() => _selectedFilter = value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey.shade300,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildFlightCard(RihlaFlightData flight, bool isDeparture) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isDeparture ? Colors.blue.shade50 : Colors.green.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            isDeparture ? Icons.flight_takeoff : Icons.flight_land,
            color: isDeparture ? Colors.blue : Colors.green,
          ),
        ),
        title: Text(
          flight.flightNumber,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        subtitle: Text(
          isDeparture
              ? '${flight.origin} → ${flight.destination} • ${flight.departureTime}'
              : '${flight.origin} → ${flight.destination} • ${flight.arrivalTime}',
          style: const TextStyle(color: Colors.grey),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              flight.airline,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
            Text(
              isDeparture ? 'Departure' : 'Arrival',
              style: TextStyle(
                fontSize: 12,
                color: isDeparture ? Colors.blue : Colors.green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        onTap: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => FlightDetailsBottomSheet(flight: flight),
          );
        },
      ),
    );
  }
}
