import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'dart:convert';
import 'dart:math' as math;

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
  double _heading = 0.0; // 進行方向
  String _distStr = "--";
  String _eta = "--";
  
  final MapController _mapController = MapController();

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
        distanceFilter: 1, // 1m単位で更新して滑らかに
      ),
    ).listen((Position p) {
      if (!mounted) return;
      setState(() {
        _currentPos = LatLng(p.latitude, p.longitude);
        _speed = p.speed * 3.6;
        if (p.heading != 0) _heading = p.heading; // 進行方向を取得
        
        if (_isNav && _autoFollow) {
          _updateCamera();
        }
        if (_isNav) _updateProgress();
      });
    });
  }

  void _updateCamera() {
    // 進行方向を上にする(rotate)、速度に合わせてズーム
    double zoom = 17.5 - math.min(2.0, _speed / 25.0);
    _mapController.rotate(-_heading); // 地図を回転
    _mapController.move(_currentPos, zoom);
  }

  // ルート上の信号だけを抽出
  Future<void> _fetchRouteSignals() async {
    if (_route.isEmpty) return;
    // ルートの中間地点から信号データを取得
    final p = _route[(_route.length / 2).floor()];
    final url = 'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent('[out:json];node(around:2000,${p.latitude},${p.longitude})["highway"="traffic_signals"];out;') }';
    
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final elements = json.decode(res.body)['elements'] as List;
        List<Marker> filtered = [];
        for (var e in elements) {
          LatLng sPos = LatLng(e['lat'], e['lon']);
          // ルート上のいずれかの点から20m以内の信号だけを表示
          bool isOnRoute = _route.any((rp) => const Distance().as(LengthUnit.Meter, rp, sPos) < 20);
          if (isOnRoute) {
            filtered.add(Marker(
              point: sPos,
              width: 30, height: 30,
              child: const Text('🚥', style: TextStyle(fontSize: 20)),
            ));
          }
        }
        setState(() => _signals = filtered);
      }
    } catch (_) {}
  }

  Future<void> _getRoute(LatLng dest) async {
    final url = 'https://router.project-osrm.org/route/v1/driving/${_currentPos.longitude},${_currentPos.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson';
    final res = await http.get(Uri.parse(url));
    if (res.statusCode == 200) {
      final List coords = json.decode(res.body)['routes'][0]['geometry']['coordinates'];
      setState(() {
        _route = coords.map((c) => LatLng(c[1].toDouble(), c[0].toDouble())).toList();
      });
      _fetchRouteSignals();
      _updateProgress();
    }
  }

  void _updateProgress() {
    if (_route.isEmpty) return;
    double meters = 0;
    for (int i = 0; i < _route.length - 1; i++) {
      meters += const Distance().as(LengthUnit.Meter, _route[i], _route[i + 1]);
    }
    setState(() {
      _distStr = meters > 1000 ? "${(meters / 1000).toStringAsFixed(1)}km" : "${meters.round()}m";
      _eta = "${(meters / (25 * 1000) * 60).round()}分";
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
              onTap: (_, p) => _showPreview(p),
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) setState(() => _autoFollow = false);
              },
            ),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
              if (_route.isNotEmpty)
                PolylineLayer(polylines: [
                  Polyline(points: _route, color: Colors.blue.withOpacity(0.7), strokeWidth: 8),
                ]),
              MarkerLayer(markers: [
                ..._signals,
                // 自車アイコン（進行方向に回転）
                Marker(
                  point: _currentPos,
                  child: Transform.rotate(
                    angle: _heading * (math.pi / 180),
                    child: const Icon(Icons.navigation, color: Colors.blue, size: 40),
                  ),
                ),
                if (_dest != null) Marker(point: _dest!, child: const Icon(Icons.location_on, color: Colors.red, size: 40)),
              ]),
            ],
          ),

          // 上部：透過検索バー
          Positioned(top: 40, left: 10, right: 10, child: _buildCompactSearch()),

          // 案内中の情報表示（フローティング）
          if (_isNav) Positioned(top: 110, left: 10, right: 10, child: _buildNavInfo()),

          // 右下：操作ボタン群
          Positioned(right: 15, bottom: 30, child: Column(children: [
            _sideBtn(Icons.my_location, () { setState(() => _autoFollow = true); _updateCamera(); }, _autoFollow ? Colors.blue : Colors.grey),
            const SizedBox(height: 10),
            if (_isNav) _sideBtn(Icons.stop, () => setState(() => _isNav = false), Colors.red),
          ])),
          
          // 目的地プレビュー（カード）
          if (_dest != null && !_isNav) Positioned(bottom: 20, left: 15, right: 15, child: _buildStartCard()),
        ],
      ),
    );
  }

  Widget _buildCompactSearch() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
      child: TypeAheadField(
        suggestionsCallback: (p) async {
          final res = await http.get(Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(p)}&format=json&limit=5&accept-language=ja'));
          return json.decode(res.body) as List;
        },
        itemBuilder: (context, s) => ListTile(title: Text(s['display_name'].split(',')[0])),
        onSelected: (s) {
          final p = LatLng(double.parse(s['lat']), double.parse(s['lon']));
          setState(() { _dest = p; _autoFollow = false; });
          _mapController.move(p, 16);
          _getRoute(p);
        },
        builder: (context, ctrl, node) => TextField(controller: ctrl, focusNode: node, decoration: const InputDecoration(hintText: '目的地を検索', border: InputBorder.none)),
      ),
    );
  }

  Widget _buildNavInfo() {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(15)),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _infoTile("到着", _eta, Colors.white),
        _infoTile("距離", _distStr, Colors.white),
        _infoTile("時速", "${_speed.toStringAsFixed(0)}km", Colors.orangeAccent),
      ]),
    );
  }

  Widget _buildStartCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text("目的地に設定しました", style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: () => setState(() => _isNav = true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
          child: const Text("案内開始"),
        ))
      ])),
    );
  }

  Widget _infoTile(String l, String v, Color c) => Column(children: [
    Text(l, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    Text(v, style: TextStyle(color: c, fontSize: 22, fontWeight: FontWeight.bold)),
  ]);

  Widget _sideBtn(IconData i, VoidCallback o, Color c) => FloatingActionButton.small(onPressed: o, backgroundColor: Colors.white, child: Icon(i, color: c));

  void _showPreview(LatLng p) {
    setState(() { _dest = p; _isNav = false; });
    _getRoute(p);
  }
}
