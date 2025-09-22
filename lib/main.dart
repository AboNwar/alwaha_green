import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'tree_list_screen.dart'; 
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter/services.dart';

Future<void> main( ) async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // تهيئة قاعدة بيانات المنطقة الزمنية
  tz.initializeTimeZones();
  
  // تهيئة الإشعارات المحلية
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = 
      FlutterLocalNotificationsPlugin();
  
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // طلب إذن الإشعارات على أندرويد 13+
  try {
    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      // إنشاء قناة إشعار لضمان الظهور
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'watering_channel',
        'إشعارات السقي',
        description: 'إشعارات تذكير سقي الأشجار',
        importance: Importance.high,
      );
      await androidPlugin.createNotificationChannel(channel);
    }
  } catch (e) {
    // تجاهل خطأ الإذن على الأنظمة غير المدعومة
  }

  // تهيئة sqflite على سطح المكتب (ويندوز/لينكس/ماك)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
  runApp(const TreeMapApp());
}

class TreeMapApp extends StatelessWidget {
  const TreeMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'خريطة الأشجار',
      theme: ThemeData(primarySwatch: Colors.green),
      debugShowCheckedModeBanner: false,
      home: const TreeMapScreen(),
    );
  }
}

class TreeMapScreen extends StatefulWidget {
  const TreeMapScreen({super.key});

  @override
  State<TreeMapScreen> createState() => _TreeMapScreenState();
}

class _TreeMapScreenState extends State<TreeMapScreen> {
  final MapController _mapController = MapController();
  LatLng _initialPosition = const LatLng(33.3152, 44.3661); // بغداد (مؤقت)
  List<Marker> _markers = [];
  Database? _database;
  List<LatLng> _routePoints = [];
  bool _isRouteVisible = false;
  LatLng? _currentUserLocation;
  bool _isDatabaseInitializing = true;
  bool _isLocationLoading = true;
  int _mapStyleIndex = 0; // فهرس نوع الخريطة الحالي
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = 
      FlutterLocalNotificationsPlugin();

  // أنواع الخرائط المختلفة
  final List<Map<String, String>> _mapStyles = [
    {
      'name': 'التضاريس',
      'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    },
    {
      'name': 'الطبيعية',
      'url': 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
    },
    {
      'name': 'الأقمار الصناعية',
      'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    },
    {
      'name': 'الطرق',
      'url': 'https://{s}.tile.thunderforest.com/transport/{z}/{x}/{y}.png?apikey=YOUR_API_KEY',
    },
  ];

  @override
  void initState() {
    super.initState();
    _initDatabaseAndLoadMarkers();
    _getCurrentLocation();
    _startLocationUpdates();
  }

  Future<void> _getCurrentLocation() async {
    try {
      print('محاولة الحصول على الموقع الحالي...');
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('خدمة تحديد الموقع غير مفعلة');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        print('طلب إذن تحديد الموقع...');
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('تم رفض إذن تحديد الموقع');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        print('تم رفض إذن تحديد الموقع نهائياً');
        return;
      }

      print('جاري الحصول على الموقع...');
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      print('تم الحصول على الموقع: ${position.latitude}, ${position.longitude}');
      
      if (mounted) {
        setState(() {
          _currentUserLocation = LatLng(position.latitude, position.longitude);
          // تحديث الموقع الابتدائي إلى الموقع الحالي
          _initialPosition = _currentUserLocation!;
          _isLocationLoading = false;
        });
        
        // تحريك الخريطة إلى الموقع الحالي
        _mapController.move(_currentUserLocation!, 16.0);
        print('تم تحديث الخريطة إلى الموقع الحالي');
      }
    } catch (e) {
      print('خطأ في الحصول على الموقع: $e');
      if (mounted) {
        setState(() {
          _isLocationLoading = false;
        });
      }
    }
  }

  void _startLocationUpdates() {
    Timer.periodic(const Duration(seconds: 30), (timer) {
      _getCurrentLocation();
    });
  }

  Future<void> _scheduleWateringNotification(int treeId, String treeName, int intervalDays) async {
    final now = DateTime.now();
    final nextWateringDate = now.add(Duration(days: intervalDays));
    final scheduleTime = tz.TZDateTime.from(nextWateringDate, tz.local);

    try {
      await _flutterLocalNotificationsPlugin.zonedSchedule(
        treeId,
        'موعد سقي الشجرة',
        'حان موعد سقي الشجرة: $treeName',
        scheduleTime,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'watering_channel',
            'إشعارات السقي',
            channelDescription: 'إشعارات تذكير سقي الأشجار',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } on PlatformException catch (e) {
      // إذا لم يُسمح بالتنبيه الدقيق على الجهاز، نستخدم وضع inexact لتجنب الاستثناء
      await _flutterLocalNotificationsPlugin.zonedSchedule(
        treeId,
        'موعد سقي الشجرة',
        'حان موعد سقي الشجرة: $treeName',
        scheduleTime,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'watering_channel',
            'إشعارات السقي',
            channelDescription: 'إشعارات تذكير سقي الأشجار',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  Future<void> _initDatabaseAndLoadMarkers() async {
    try {
      print('بدء تهيئة قاعدة البيانات...');
      String dbPath = await getDatabasesPath();
      String path = '$dbPath/trees.db';
      print('مسار قاعدة البيانات: $path');

      _database = await openDatabase(
        path,
        version: 1,
        onCreate: (db, version) async {
          print('إنشاء جدول الأشجار...');
          await db.execute(
            'CREATE TABLE trees('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'name TEXT, '
            'number TEXT, '
            'lat REAL, '
            'lon REAL, '
            'watering_date TEXT, '
            'watering_interval INTEGER DEFAULT 7'
            ')',
          );
          print('تم إنشاء جدول الأشجار بنجاح');
        },
        onOpen: (db) async {
          // ضمان وجود الأعمدة في حال كانت قاعدة بيانات قديمة بدونها
          try {
            final List<Map<String, Object?>> columns =
                await db.rawQuery("PRAGMA table_info(trees)");
            final Set<String> columnNames =
                columns.map((row) => (row['name'] as String).toLowerCase()).toSet();

            if (!columnNames.contains('watering_date')) {
              await db.execute('ALTER TABLE trees ADD COLUMN watering_date TEXT');
              print('تمت إضافة العمود watering_date');
            }
            if (!columnNames.contains('watering_interval')) {
              await db.execute('ALTER TABLE trees ADD COLUMN watering_interval INTEGER DEFAULT 7');
              print('تمت إضافة العمود watering_interval');
            }
          } catch (e) {
            print('خطأ أثناء التحقق/إضافة الأعمدة: $e');
          }
        },
      );
      print('تم فتح قاعدة البيانات بنجاح');
      
      await _loadMarkersFromDb();
      
      if (mounted) {
        setState(() {
          _isDatabaseInitializing = false;
        });
        print('تم الانتهاء من تهيئة قاعدة البيانات');
      }
    } catch (e) {
      print('خطأ في تهيئة قاعدة البيانات: $e');
      if (mounted) {
        setState(() {
          _isDatabaseInitializing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ في قاعدة البيانات: $e')),
        );
      }
    }
  }

  Future<void> _loadMarkersFromDb() async {
    if (_database == null) return;

    final List<Map<String, dynamic>> maps = await _database!.query('trees');
    List<Marker> loadedMarkers = [];
    for (var map in maps) {
      final lat = map['lat'];
      final lon = map['lon'];
      if (lat != null && lon != null) {
        final treeLocation = LatLng(lat, lon);
        loadedMarkers.add(
          Marker(
            point: treeLocation,
            width: 80,
            height: 80,
            child: GestureDetector(
              onTap: () => _drawRouteToTree(treeLocation),
              child: Tooltip(
                message: 'الاسم: ${map['name']}\nالرقم: ${map['number']}',
                child: const Icon(Icons.park, color: Colors.green, size: 35),
              ),
            ),
          ),
        );
      }
    }

    if (mounted) {
      setState(() {
        _markers = loadedMarkers;
      });
    }
  }

  Future<void> _addTree(LatLng position) async {
    print('محاولة إضافة شجرة في الموقع: ${position.latitude}, ${position.longitude}');
    print('حالة قاعدة البيانات: _isDatabaseInitializing = $_isDatabaseInitializing, _database = $_database');
    
    if (_isDatabaseInitializing || _database == null) {
      print('قاعدة البيانات غير جاهزة');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('قاعدة البيانات غير جاهزة بعد، يرجى الانتظار.'))
      );
      return;
    }

    print('فتح نافذة إضافة شجرة');
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _AddTreeDialog(position: position),
    );

    if (result == null) {
      print('تم إلغاء إضافة الشجرة');
      return;
    }
    
    print('بيانات الشجرة: $result');

    try {
      print('بدء إدراج الشجرة في قاعدة البيانات');
      final int treeId = await _database!.insert(
        'trees',
        {
          'name': result['name'],
          'number': result['number'],
          'lat': position.latitude,
          'lon': position.longitude,
          'watering_date': (result['watering_date'] as DateTime).toIso8601String(),
          'watering_interval': result['watering_interval'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print('تم إدراج الشجرة بنجاح مع ID: $treeId');

      // جدولة الإشعار للسقي
      print('بدء جدولة الإشعار');
      await _scheduleWateringNotification(
        treeId, 
        result['name'], 
        result['watering_interval']
      );
      print('تم جدولة الإشعار بنجاح');

      print('إعادة تحميل العلامات');
      await _loadMarkersFromDb();
      print('تم إعادة تحميل العلامات بنجاح');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إضافة الشجرة "${result['name']}" بنجاح!'))
        );
      }
    } catch (e) {
      print('خطأ في إضافة الشجرة: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ في إضافة الشجرة: $e'))
        );
      }
    }
  }

  Future<void> _goToCurrentUserLocation() async {
    if (_currentUserLocation != null) {
      _mapController.move(_currentUserLocation!, 16.0);
      return;
    }

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('خدمة تحديد الموقع غير مفعلة')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    try {
      final Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final userLocation = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentUserLocation = userLocation;
      });
      _mapController.move(userLocation, 16.0);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ في تحديد الموقع: $e')));
    }
  }

  Future<void> _drawRouteToTree(LatLng treeLocation) async {
    try {
      LatLng startPoint;
      
      if (_currentUserLocation != null) {
        startPoint = _currentUserLocation!;
      } else {
        final Position currentPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        startPoint = LatLng(currentPosition.latitude, currentPosition.longitude);
        setState(() {
          _currentUserLocation = startPoint;
        });
      }
      
      await _getRouteFromAPI(startPoint, treeLocation);

      if (mounted) {
        setState(() {
          _isRouteVisible = true;
        });
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [startPoint, treeLocation],
            padding: const EdgeInsets.all(50),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('لا يمكن الحصول على الموقع الحالي لرسم المسار. $e')),
        );
      }
    }
  }

  Future<void> _getRouteFromAPI(LatLng start, LatLng end) async {
    final url = 'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=polyline';
    try {
      final response = await http.get(Uri.parse(url ));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final geometry = data['routes'][0]['geometry'];
          setState(() => _routePoints = _decodePolyline(geometry));
          return;
        }
      }
    } catch (e) {
      // Fallback to a straight line in case of API error
    }
    setState(() => _routePoints = [start, end]);
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('خريطة الأشجار - ${_mapStyles[_mapStyleIndex]['name']}'),
        actions: [
          IconButton(icon: const Icon(Icons.my_location), onPressed: _goToCurrentUserLocation),
          IconButton(
            icon: const Icon(Icons.layers),
            onPressed: () => _showMapStyleDialog(),
            tooltip: 'تغيير نوع الخريطة',
          ),
          IconButton(
            icon: _isDatabaseInitializing 
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.list),
            onPressed: _isDatabaseInitializing ? null : () async {
              if (_database == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('خطأ في قاعدة البيانات'))
                );
                return;
              }
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TreeListScreen(
                    database: _database!,
                    onRouteRequested: _drawRouteToTree,
                  ),
                ),
              );
            },
            tooltip: _isDatabaseInitializing ? 'جاري تحميل قاعدة البيانات...' : 'عرض قائمة الأشجار',
          ),
          if (_isRouteVisible)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _isRouteVisible = false;
                _routePoints = [];
              }),
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialPosition,
              initialZoom: 13.0,
              onTap: (tapPosition, point) => _addTree(point),
            ),
            children: [
          TileLayer(
            urlTemplate: _mapStyles[_mapStyleIndex]['url']!,
            subdomains: const ['a', 'b', 'c'],
            userAgentPackageName: 'com.example.final_tree_project',
           ),
          MarkerLayer(markers: _markers),
          if (_currentUserLocation != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _currentUserLocation!,
                  width: 40,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: const Icon(
                      Icons.person,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          if (_isRouteVisible)
            PolylineLayer(
              polylines: [Polyline(points: _routePoints, color: Colors.blue, strokeWidth: 5)],
            ),
            ],
          ),
          if (_isDatabaseInitializing || _isLocationLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(20.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('جاري تحميل التطبيق...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showMapStyleDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اختر نوع الخريطة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _mapStyles.asMap().entries.map((entry) {
            int index = entry.key;
            Map<String, String> style = entry.value;
            bool isSelected = index == _mapStyleIndex;
            
            return ListTile(
              leading: Radio<int>(
                value: index,
                groupValue: _mapStyleIndex,
                onChanged: (int? value) {
                  if (value != null) {
                    setState(() {
                      _mapStyleIndex = value;
                    });
                    Navigator.pop(context);
                  }
                },
              ),
              title: Text(style['name']!),
              selected: isSelected,
              onTap: () {
                setState(() {
                  _mapStyleIndex = index;
                });
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }
}

class _AddTreeDialog extends StatefulWidget {
  final LatLng position;
  const _AddTreeDialog({required this.position});

  @override
  State<_AddTreeDialog> createState() => _AddTreeDialogState();
}

class _AddTreeDialogState extends State<_AddTreeDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _numberController = TextEditingController();
  DateTime _wateringDate = DateTime.now();
  int _wateringInterval = 7; // عدد الأيام بين كل سقي

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة شجرة جديدة'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'اسم الشجرة'),
                validator: (value) => (value == null || value.isEmpty) ? 'الرجاء إدخال اسم' : null,
              ),
              TextFormField(
                controller: _numberController,
                decoration: const InputDecoration(labelText: 'رقم الشجرة'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text('تاريخ السقي:'),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _wateringDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (date != null) setState(() => _wateringDate = date);
                    },
                    child: Text(DateFormat('yyyy/MM/dd').format(_wateringDate)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text('فترة السقي (أيام):'),
                  const Spacer(),
                  DropdownButton<int>(
                    value: _wateringInterval,
                    items: [1, 2, 3, 4, 5, 6, 7, 10, 14, 21, 30].map((int value) {
                      return DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value يوم'),
                      );
                    }).toList(),
                    onChanged: (int? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _wateringInterval = newValue;
                        });
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(
          onPressed: () {
            print('تم الضغط على زر الإضافة');
            if (_formKey.currentState!.validate()) {
              print('التحقق من النموذج نجح');
              final data = {
                'name': _nameController.text,
                'number': _numberController.text,
                'watering_date': _wateringDate,
                'watering_interval': _wateringInterval,
              };
              print('إرجاع البيانات: $data');
              Navigator.pop(context, data);
            } else {
              print('التحقق من النموذج فشل');
            }
          },
          child: const Text('إضافة'),
        ),
      ],
    );
  }
}
