import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:latlong2/latlong.dart';

class TreeListScreen extends StatefulWidget {
  final Database database;
  // هذه الدالة يتم تمريرها من الشاشة الرئيسية لرسم المسار
  final Future<void> Function(LatLng treeLocation) onRouteRequested;

  const TreeListScreen({
    super.key,
    required this.database,
    required this.onRouteRequested,
  });

  @override
  State<TreeListScreen> createState() => _TreeListScreenState();
}

class _TreeListScreenState extends State<TreeListScreen> {
  List<Map<String, dynamic>> _trees = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTrees();
  }

  Future<void> _loadTrees() async {
    setState(() => _isLoading = true);
    final List<Map<String, dynamic>> maps = await widget.database.query(
      'trees',
      orderBy: 'id DESC',
    );
    if (mounted) {
      setState(() {
        _trees = maps;
        _isLoading = false;
      });
    }
  }

  // فتح خرائط Google للشجرة
  Future<void> _openGoogleMap(double? lat, double? lon) async {
    if (lat == null || lon == null) return;
    final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon' );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      // إظهار رسالة خطأ للمستخدم
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يمكن فتح خرائط Google')),
        );
      }
    }
  }

  // حساب الأيام المتبقية للسقي
  int _daysUntilWatering(String? wateringDateStr, int wateringInterval) {
    if (wateringDateStr == null) return 0;
    try {
      DateTime lastWateringDate = DateTime.parse(wateringDateStr);
      DateTime today = DateTime.now();
      DateTime todayDateOnly = DateTime(today.year, today.month, today.day);
      DateTime lastWateringDateOnly = DateTime(lastWateringDate.year, lastWateringDate.month, lastWateringDate.day);

      // حساب موعد السقي التالي
      DateTime nextWateringDate = lastWateringDateOnly.add(Duration(days: wateringInterval));
      final difference = nextWateringDate.difference(todayDateOnly).inDays;
      return difference >= 0 ? difference : 0;
    } catch (e) {
      return 0;
    }
  }

  // حساب موعد السقي التالي
  String _getNextWateringDate(String? wateringDateStr, int wateringInterval) {
    if (wateringDateStr == null) return 'غير محدد';
    try {
      DateTime lastWateringDate = DateTime.parse(wateringDateStr);
      DateTime nextWateringDate = lastWateringDate.add(Duration(days: wateringInterval));
      return DateFormat('yyyy-MM-dd').format(nextWateringDate);
    } catch (e) {
      return 'غير محدد';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('قائمة الأشجار'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTrees,
            tooltip: 'تحديث القائمة',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _trees.isEmpty
              ? const Center(child: Text('لا توجد أشجار مضافة بعد.'))
              : ListView.builder(
                  itemCount: _trees.length,
                  itemBuilder: (context, index) {
                    final tree = _trees[index];
                    final name = tree['name']?.toString() ?? 'بدون اسم';
                    final number = tree['number']?.toString() ?? 'بدون رقم';
                    final lat = tree['lat'] as double?;
                    final lon = tree['lon'] as double?;
                    final wateringDateStr = tree['watering_date'] as String?;
                    final wateringInterval = tree['watering_interval'] as int? ?? 7;
                    final daysLeft = _daysUntilWatering(wateringDateStr, wateringInterval);
                    final lastWateringDate = wateringDateStr != null
                        ? DateFormat('yyyy-MM-dd').format(DateTime.parse(wateringDateStr))
                        : 'غير محدد';
                    final nextWateringDate = _getNextWateringDate(wateringDateStr, wateringInterval);

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: daysLeft <= 1 ? Colors.red : daysLeft <= 3 ? Colors.orange : Colors.green,
                          child: Text('${index + 1}', style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text('$name (رقم: $number)'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('آخر سقي: $lastWateringDate'),
                            Text('موعد السقي التالي: $nextWateringDate'),
                            Text('فترة السقي: كل $wateringInterval أيام'),
                            Text(
                              'الأيام المتبقية: $daysLeft',
                              style: TextStyle(
                                color: daysLeft <= 1 ? Colors.red : daysLeft <= 3 ? Colors.orange : Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        trailing: Wrap(
                          spacing: 0, // المسافة بين الأيقونات
                          children: [
                            IconButton(
                              icon: const Icon(Icons.map, color: Colors.blue),
                              tooltip: 'عرض على خرائط Google',
                              onPressed: () => _openGoogleMap(lat, lon),
                            ),
                            IconButton(
                              icon: const Icon(Icons.directions, color: Colors.green),
                              tooltip: 'رسم المسار إلى الشجرة',
                              onPressed: () {
                                if (lat != null && lon != null) {
                                  widget.onRouteRequested(LatLng(lat, lon));
                                  Navigator.pop(context); // العودة لشاشة الخريطة
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
