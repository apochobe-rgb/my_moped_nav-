import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:intl/intl.dart';

void main() => runApp(const MopedNavApp());

class MopedNavApp extends StatelessWidget {
  const MopedNavApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.orange),
      debugShowCheckedModeBanner: false,
      home: const MapPage(),
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  LatLng _currentPos = const LatLng(35.6812, 139.7671);
  LatLng? _dest;
  List<LatLng> _route = [];
  List<Marker> _signals = [];
  
  bool _isNav = false;
  bool _autoFollow = true;
  double _speed = 0.0;
  double _heading = 0.0; 
  String _distStr = "--";
  String _etaTime = "--"; 
  String _durationStr = "--"; 
  
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  void _startTracking() async {
    await Geolocator.requestPermission();
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2, 
      ),
    ).listen((Position p) {
      if (!mounted) return;
      setState(() {
        _currentPos = LatLng(p.latitude, p.longitude);
        _speed = p.speed * 3.6;
        if (p.heading != 0) _heading = p.heading;
        
        if (_isNav) {
          if (_autoFollow) _updateCamera();
          _checkReroute(); 
          _updateProgress();
        }
      });
    });
  }

  void _updateCamera() {
    double zoom = 17.5 - math.min(2.0, _speed / 25.0);
    _mapController.rotate(-_heading); 
    _mapController.move(_currentPos, zoom);
  }

  void _checkReroute() {
    if (_route.isEmpty || _dest == null) return;
    double minDev = _route.map((rp) => const Distance().as(LengthUnit.Meter, _currentPos, rp)).reduce(math.min);
    if (minDev > 50) {
      _getRoute(_dest!, fitBounds: false);
    }
  }

  Future<void> _getRoute(LatLng dest, {bool fitBounds = true}) async {
    final url = 'https://router.project-osrm.org/route/v1/driving/${_currentPos.longitude},${_currentPos.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final List coords = json.decode(res.body)['routes'][0]['geometry']['coordinates'];
        setState(() {
          _route = coords.map((c) => LatLng(c[1].toDouble(), c[0].toDouble())).toList();
        });
        
        if (fitBounds) {
          final bounds = LatLngBounds.fromPoints(_route);
          _mapController.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)));
        }
        _fetchRouteSignals();
        _updateProgress();
      }
    } catch (_) {}
  }

  Future<void> _fetchRouteSignals() async {
    if (_route.isEmpty) return;
    final p = _route[(_route.length / 2).floor()];
    final url = 'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent('[out:json];node(around:2000,${p.latitude},${p.longitude})["highway"="traffic_signals"];out;') }';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final elements = json.decode(res.body)['elements'] as List;
        List<Marker> filtered = [];
        for (var e in elements) {
          LatLng sPos = LatLng(e['lat'], e['lon']);
          bool isOnRoute = _route.any((rp) => const Distance().as(LengthUnit.Meter, rp, sPos) < 15);
          if (isOnRoute) {
            filtered.add(Marker(point: sPos, width: 30, height: 30, child: const Text('🚥', style: TextStyle(fontSize: 18))));
          }
        }
        setState(() => _signals = filtered);
      }
    } catch (_) {}
  }

  void _updateProgress() {
    if (_route.isEmpty) return;
    double meters = 0;
    for (int i = 0; i < _route.length - 1; i++) {
      meters += const Distance().as(LengthUnit.Meter, _route[i], _route[i + 1]);
    }
    int minutes = (meters / (25 * 1000) * 60).round();
    DateTime arrival = DateTime.now().add(Duration(minutes: minutes));
    
    setState(() {
      _distStr = meters > 1000 ? "${(meters / 1000).toStringAsFixed(1)}km" : "${meters.round()}m";
      _durationStr = "$minutes分";
      _etaTime = DateFormat('H:mm').format(arrival);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPos,
              initialZoom: 16.0,
              onTap: (_, p) { if(!_isNav) _showPreview(p); },
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _isNav) setState(() => _autoFollow = false);
              },
            ),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
              if (_route.isNotEmpty) PolylineLayer(polylines: [
                Polyline(points: _route, color: Colors.blue.withOpacity(0.8), strokeWidth: 8),
              ]),
              MarkerLayer(markers: [
                ..._signals,
                Marker(
                  point: _currentPos,
                  child: Transform.rotate(
                    angle: _heading * (math.pi / 180),
                    child: const Icon(Icons.navigation, color: Colors.blue, size: 45),
                  ),
                ),
                if (_dest != null) Marker(point: _dest!, child: const Icon(Icons.location_on, color: Colors.red, size: 45)),
              ]),
            ],
          ),

          if (!_isNav) Positioned(top: 40, left: 10, right: 10, child: _buildSearchBox()),

          if (_isNav) Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomNavInfo()),
          
          if (_isNav && !_autoFollow) Positioned(right: 15, bottom: 120, child: FloatingActionButton.small(
            onPressed: () => setState(() => _autoFollow = true),
            child: const Icon(Icons.my_location),
          )),

          if (_dest != null && !_isNav) Positioned(bottom: 20, left: 15, right: 15, child: _buildConfirmCard()),
        ],
      ),
    );
  }

  Widget _buildSearchBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
      child: TypeAheadField(
        controller: _searchController,
        suggestionsCallback: (p) async {
          final res = await http.get(Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(p)}&format=json&limit=5&accept-language=ja'));
          return json.decode(res.body) as List;
        },
        itemBuilder: (context, s) => ListTile(title: Text(s['display_name'].split(',')[0])),
        onSelected: (s) {
          final p = LatLng(double.parse(s['lat']), double.parse(s['lon']));
          _showPreview(p);
        },
        builder: (context, ctrl, node) => TextField(controller: ctrl, focusNode: node, decoration: const InputDecoration(hintText: '目的地を検索', border: InputBorder.none)),
      ),
    );
  }

  Widget _buildBottomNavInfo() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 25),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(_etaTime, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text("($_durationStr)", style: const TextStyle(fontSize: 16, color: Colors.grey)),
          ]),
          Text("残り $_distStr", style: const TextStyle(color: Colors.blueGrey, fontSize: 14)),
        ])),
        Column(children: [
          Text(_speed.toStringAsFixed(0), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.orange)),
          const Text("km/h", style: TextStyle(fontSize: 10, color: Colors.orange)),
        ]),
        const SizedBox(width: 15),
        // エラー修正箇所：styleパラメータを使用
        IconButton.filled(
          onPressed: () => setState(() => _isNav = false), 
          icon: const Icon(Icons.close),
          style: IconButton.styleFrom(backgroundColor: Colors.red),
        ),
      ]),
    );
  }

  Widget _buildConfirmCard() {
    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text("経路を確認", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text("到着予定: $_etaTime ($_durationStr)", style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 15),
        SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(
          onPressed: () {
            setState(() { _isNav = true; _autoFollow = true; });
            _updateCamera();
          },
          icon: const Icon(Icons.navigation),
          label: const Text("案内を開始", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
        ))
      ])),
    );
  }

  void _showPreview(LatLng p) {
    setState(() { _dest = p; _isNav = false; });
    _getRoute(p);
  }
}
