import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'dart:convert';
import 'dart:math' as math;

void main() => runApp(const MyApp());

enum TransportMode { moped, car, walk }

enum RouteType { fastest, shortest, easy }

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
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
  LatLng _currentLocation = const LatLng(35.6812, 139.7671);
  LatLng? _destination;
  LatLng? _previewLocation;
  String _previewInfo = "";

  List<LatLng> _routePoints = [];
  List<Marker> _signalMarkers = [];

  // ★ これらの変数をロジックに組み込みます
  TransportMode _mode = TransportMode.moped;
  RouteType _routeType = RouteType.fastest;

  bool _isNavigating = false;
  bool _autoFollow = true;

  String _eta = "--";
  String _distanceRemaining = "--";
  double _speed = 0.0;

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
        _currentLocation = LatLng(p.latitude, p.longitude);
        _speed = p.speed * 3.6;
        if (_isNavigating && _autoFollow) _moveToCurrentLocation();
        if (_isNavigating) _recalculateProgress(_currentLocation);
      });
    });
  }

  void _moveToCurrentLocation() {
    double calculatedZoom = 17.5 - math.min(2.5, _speed / 24.0);
    double offset = 0.002 / math.pow(2, calculatedZoom - 15);
    _mapController.move(
      LatLng(_currentLocation.latitude + offset, _currentLocation.longitude),
      calculatedZoom,
    );
  }

  Future<void> _fetchSignalsForRoute() async {
    if (_routePoints.isEmpty) return;
    final p = _routePoints[(_routePoints.length / 2).floor()];
    final query =
        '[out:json];node(around:2000,${p.latitude},${p.longitude})["highway"="traffic_signals"];out;';
    final url =
        'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final elements = json.decode(res.body)['elements'] as List;
        setState(() {
          _signalMarkers = elements
              .map(
                (e) => Marker(
                  point: LatLng(e['lat'], e['lon']),
                  width: 40,
                  height: 40,
                  child: const Icon(
                    Icons.traffic_rounded,
                    color: Colors.blueGrey,
                    size: 28,
                  ),
                ),
              )
              .toList();
        });
      }
    } catch (e) {
      debugPrint("Signals Error: $e");
    }
  }

  // ★ 経路検索で _mode と _routeType を使用
  Future<void> _getRoute(LatLng dest) async {
    // 徒歩なら walking、それ以外は driving プロファイルを使用
    String profile = _mode == TransportMode.walk ? 'walking' : 'driving';

    // 最短(shortest)の場合は alternatives=true にして短い方を選ぶ
    String url =
        'https://router.project-osrm.org/route/v1/$profile/'
        '${_currentLocation.longitude},${_currentLocation.latitude};'
        '${dest.longitude},${dest.latitude}?overview=full&geometries=geojson&alternatives=true';

    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        var routes = data['routes'] as List;
        var selectedRoute = routes[0];

        // 最短アルゴリズム: 距離が一番短いルートを探す
        if (_routeType == RouteType.shortest) {
          selectedRoute = routes.reduce(
            (a, b) => a['distance'] < b['distance'] ? a : b,
          );
        }

        final List coords = selectedRoute['geometry']['coordinates'];
        setState(() {
          _routePoints = coords
              .map((c) => LatLng(c[1].toDouble(), c[0].toDouble()))
              .toList();
          _recalculateProgress(_currentLocation);
          _fetchSignalsForRoute();
        });
      }
    } catch (e) {
      debugPrint("Route Error: $e");
    }
  }

  void _recalculateProgress(LatLng current) {
    if (_routePoints.isEmpty) return;
    double totalMeters = 0;
    for (int i = 0; i < _routePoints.length - 1; i++) {
      totalMeters += const Distance().as(
        LengthUnit.Meter,
        _routePoints[i],
        _routePoints[i + 1],
      );
    }
    setState(() {
      _distanceRemaining = totalMeters > 1000
          ? "${(totalMeters / 1000).toStringAsFixed(1)}km"
          : "${totalMeters.round()}m";
      // モードに合わせてETAを変える
      double avgSpeed = _mode == TransportMode.walk ? 4.5 : 30.0;
      _eta = "${(totalMeters / (avgSpeed * 1000) * 60).round()}分";
    });
  }

  void _handleMapTap(LatLng point) async {
    setState(() {
      _previewLocation = point;
      _previewInfo = "読み込み中...";
    });
    final url =
        'https://nominatim.openstreetmap.org/search?q=${point.latitude},${point.longitude}&format=json&accept-language=ja&addressdetails=1';
    final res = await http.get(
      Uri.parse(url),
      headers: {'User-Agent': 'moped_nav'},
    );
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      if (data is List && data.isNotEmpty) {
        final addr = data[0]['address'];
        final name =
            data[0]['name'] ?? addr['suburb'] ?? addr['city'] ?? "指定した地点";
        final dist = const Distance().as(
          LengthUnit.Meter,
          _currentLocation,
          point,
        );
        final distStr = dist > 1000
            ? "${(dist / 1000).toStringAsFixed(1)}km"
            : "${dist}m";
        final fullAddr =
            "${addr['city'] ?? ''}${addr['suburb'] ?? ''}${addr['road'] ?? ''}";
        setState(() {
          _previewInfo = "$name ($distStr) ($fullAddr)";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 15.0,
              onTap: (tapPos, point) => _handleMapTap(point),
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _autoFollow)
                  setState(() => _autoFollow = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      color: Colors.blueAccent,
                      strokeWidth: 8.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_isNavigating) ..._signalMarkers,
                  Marker(
                    point: _currentLocation,
                    child: const Icon(
                      Icons.navigation,
                      color: Colors.blue,
                      size: 40,
                    ),
                  ),
                  if (_previewLocation != null)
                    Marker(
                      point: _previewLocation!,
                      child: const Icon(
                        Icons.location_searching,
                        color: Colors.orange,
                        size: 30,
                      ),
                    ),
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 45,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 上部：検索とモード切替
          Positioned(
            top: 50,
            left: 15,
            right: 15,
            child: Column(
              children: [
                _buildSearchBar(),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _modeChip("原付", TransportMode.moped),
                      _modeChip("自動車", TransportMode.car),
                      _modeChip("徒歩", TransportMode.walk),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 右側：ボタン
          Positioned(
            right: 20,
            bottom: _destination != null || _previewLocation != null
                ? 350
                : 100,
            child: Column(
              children: [
                _circleButton(
                  Icons.add,
                  () => _mapController.move(
                    _mapController.camera.center,
                    _mapController.camera.zoom + 1,
                  ),
                ),
                const SizedBox(height: 10),
                _circleButton(
                  Icons.remove,
                  () => _mapController.move(
                    _mapController.camera.center,
                    _mapController.camera.zoom - 1,
                  ),
                ),
                const SizedBox(height: 10),
                _circleButton(Icons.my_location, () {
                  setState(() => _autoFollow = true);
                  _moveToCurrentLocation();
                }, _autoFollow ? Colors.blue : Colors.red),
              ],
            ),
          ),

          if (_previewLocation != null && !_isNavigating)
            Positioned(
              bottom: 20,
              left: 15,
              right: 15,
              child: _buildPreviewPanel(),
            ),

          if (_destination != null && _isNavigating)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomPanel(),
            ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, TransportMode mode) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: _mode == mode,
        onSelected: (v) {
          setState(() => _mode = mode);
          if (_destination != null) _getRoute(_destination!);
        },
      ),
    );
  }

  Widget _buildPreviewPanel() {
    final parts = _previewInfo.split(' (');
    final name = parts[0];
    final subInfo = parts.length > 1 ? "(${parts[1]} (${parts[2]}" : "";
    return Card(
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              subInfo,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _destination = _previewLocation;
                        _previewLocation = null;
                        _isNavigating = true;
                        _autoFollow = true;
                      });
                      _getRoute(_destination!);
                      _moveToCurrentLocation();
                    },
                    icon: const Icon(Icons.navigation),
                    label: const Text("目的地に設定して出発"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: () => setState(() => _previewLocation = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Card(
      elevation: 5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      child: TypeAheadField(
        controller: _searchController,
        suggestionsCallback: (p) async {
          final url =
              'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(p)}&format=json&limit=5&accept-language=ja';
          final res = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'moped_nav'},
          );
          return json.decode(res.body) as List;
        },
        itemBuilder: (context, s) =>
            ListTile(title: Text(s['display_name'].split(',')[0])),
        onSelected: (s) {
          final dest = LatLng(double.parse(s['lat']), double.parse(s['lon']));
          setState(() {
            _destination = dest;
            _isNavigating = false;
            _previewLocation = dest;
            _handleMapTap(dest);
          });
          _mapController.move(dest, 16.0);
        },
        builder: (context, controller, focusNode) => TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            hintText: '目的地を検索',
            prefixIcon: Icon(Icons.search),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 30),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statText("到着予想", _eta),
              _statText("残り距離", _distanceRemaining),
              _statText("速度", "${_speed.toStringAsFixed(0)}km/h"),
            ],
          ),
          const SizedBox(height: 15),
          // ★ 経路タイプ切替
          SegmentedButton<RouteType>(
            segments: const [
              ButtonSegment(value: RouteType.fastest, label: Text("最速")),
              ButtonSegment(value: RouteType.shortest, label: Text("最短")),
              ButtonSegment(value: RouteType.easy, label: Text("楽")),
            ],
            selected: {_routeType},
            onSelectionChanged: (v) {
              setState(() => _routeType = v.first);
              if (_destination != null) _getRoute(_destination!);
            },
          ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () => setState(() => _isNavigating = false),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                "案内を停止",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statText(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      Text(
        value,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
    ],
  );

  Widget _circleButton(
    IconData icon,
    VoidCallback onTap, [
    Color color = Colors.black87,
  ]) => FloatingActionButton.small(
    onPressed: onTap,
    backgroundColor: Colors.white,
    child: Icon(icon, color: color),
    heroTag: null,
  );
}
