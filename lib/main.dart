import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SmartParkApp());
}

const green = Color(0xFF22C55E);
const lightGreen = Color(0xFFE8F5E9);
const greyBg = Color(0xFFF5F5F5);
const double pricePerHour = 2.0;

// Firestore: users/{uid}, spots/{spotName}, sessions/{id}
DocumentReference<Map<String, dynamic>>? userDoc() {
  final u = FirebaseAuth.instance.currentUser;
  if (u == null) return null;
  return FirebaseFirestore.instance.collection('users').doc(u.uid);
}

CollectionReference<Map<String, dynamic>> spotsCol() =>
    FirebaseFirestore.instance.collection('spots');
CollectionReference<Map<String, dynamic>> sessionsCol() =>
    FirebaseFirestore.instance.collection('sessions');

void showMsg(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), backgroundColor: error ? Colors.red : green),
  );
}

const Map<String, List<Map<String, String>>> parkingData = {
  'University Parking': [
    {'name': 'Spot A-12', 'distance': '0.03 km'},
    {'name': 'Spot A-26', 'distance': '1 km'},
    {'name': 'Spot A-44', 'distance': '1.5 km'},
  ],
  'Mall Parking': [
    {'name': 'Spot B-10', 'distance': '0.08 km'},
    {'name': 'Spot B-21', 'distance': '0.12 km'},
    {'name': 'Spot B-35', 'distance': '0.20 km'},
  ],
  'Hospital Parking': [
    {'name': 'Spot C-05', 'distance': '10 km'},
    {'name': 'Spot C-14', 'distance': '10.2 km'},
    {'name': 'Spot C-22', 'distance': '10.5 km'},
  ],
};

const Map<String, String> parkingDistance = {
  'University Parking': '0.03 km',
  'Mall Parking': '0.08 km',
  'Hospital Parking': '10 km',
};

class ParkingSession {
  final String id;
  final String spotName;
  final String parkingName;
  final DateTime start;
  ParkingSession({
    required this.id,
    required this.spotName,
    required this.parkingName,
    required this.start,
  });
}

Stream<Set<String>> occupiedStream() {
  return spotsCol().snapshots().map((snap) {
    final set = <String>{};
    for (final d in snap.docs) {
      if (d.data()['occupied'] == true) set.add(d.id);
    }
    return set;
  }).handleError((_) {});
}

ParkingSession _toSession(QueryDocumentSnapshot<Map<String, dynamic>> d) {
  final data = d.data();
  final ts = data['start'];
  return ParkingSession(
    id: d.id,
    spotName: data['spotName'] as String,
    parkingName: data['parkingName'] as String,
    start: ts is Timestamp ? ts.toDate() : DateTime.now(),
  );
}

Stream<ParkingSession?> activeSessionStream() {
  final u = FirebaseAuth.instance.currentUser;
  if (u == null) return Stream.value(null);
  return sessionsCol()
      .where('userId', isEqualTo: u.uid)
      .where('status', isEqualTo: 'active')
      .snapshots()
      .map((s) => s.docs.isEmpty ? null : _toSession(s.docs.first))
      .handleError((_) {});
}

Future<String?> checkInSpot({
  required String spotName,
  required String parkingName,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return 'Please log in first.';
  try {
    final mine = await sessionsCol()
        .where('userId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    if (mine.docs.isNotEmpty) return 'You already have an active session.';

    final spotRef = spotsCol().doc(spotName);
    final sessionRef = sessionsCol().doc();
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final spot = await tx.get(spotRef);
      if (spot.exists && spot.data()?['occupied'] == true) throw 'taken';
      tx.set(spotRef, {
        'occupied': true,
        'userId': user.uid,
        'parkingName': parkingName,
        'since': FieldValue.serverTimestamp(),
      });
      tx.set(sessionRef, {
        'userId': user.uid,
        'spotName': spotName,
        'parkingName': parkingName,
        'status': 'active',
        'start': FieldValue.serverTimestamp(),
      });
    });
    return null;
  } catch (e) {
    if (e == 'taken') return 'Sorry, this spot was just taken.';
    return 'Could not check-in. Check Firestore rules.';
  }
}

Future<String?> checkOutSession(
    ParkingSession s, Duration duration, double cost) async {
  try {
    final batch = FirebaseFirestore.instance.batch();
    batch.update(sessionsCol().doc(s.id), {
      'status': 'done',
      'end': FieldValue.serverTimestamp(),
      'durationSeconds': duration.inSeconds,
      'cost': double.parse(cost.toStringAsFixed(2)),
    });
    batch.set(spotsCol().doc(s.spotName), {
      'occupied': false,
      'userId': null,
      'parkingName': s.parkingName,
    });
    await batch.commit();
    return null;
  } catch (e) {
    return 'Could not check-out. Check Firestore rules.';
  }
}

String formatTime(DateTime t) {
  final hour = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
  final minute = t.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${t.hour >= 12 ? 'PM' : 'AM'}';
}

String formatDate(DateTime t) {
  const m = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${t.day} ${m[t.month - 1]} ${t.year}';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

double calculateCost(Duration d) {
  final minutes = (d.inSeconds / 60).ceil();
  return (minutes < 1 ? 1 : minutes) * (pricePerHour / 60);
}

class SmartParkApp extends StatelessWidget {
  const SmartParkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartPark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: green),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: green)),
            );
          }
          if (snapshot.hasData) return const MainNavigation();
          return const SplashScreen();
        },
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 105,
                height: 105,
                decoration: BoxDecoration(
                  color: lightGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: green, width: 4),
                ),
                child: const Icon(Icons.location_on, size: 62, color: green),
              ),
              const SizedBox(height: 8),
              const Icon(Icons.directions_car, size: 52, color: green),
              const SizedBox(height: 12),
              const Text('SmartPark',
                  style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold, color: green)),
              const SizedBox(height: 4),
              const Text('Find parking easily and save time',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const LoginScreen())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Get Started',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool hidePassword = true;
  bool loading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool signUp}) async {
    final email = emailController.text;
    final pass = passwordController.text;
    if (email.isEmpty || pass.isEmpty) {
      showMsg(context, 'Please enter email and password.', error: true);
      return;
    }
    setState(() => loading = true);
    final error = signUp
        ? await AuthService.signUp(email, pass)
        : await AuthService.login(email, pass);
    if (!mounted) return;
    setState(() => loading = false);
    if (error != null) {
      showMsg(context, error, error: true);
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _forgotPassword() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      showMsg(context, 'Enter your email first.', error: true);
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      showMsg(context, 'Password reset link sent to $email');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      showMsg(context, 'Could not send reset email (${e.code}).', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              const Text('Welcome Back!',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Login to continue',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 28),
              const Text('Email',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 7),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'example@gmail.com',
                  prefixIcon: const Icon(Icons.email_outlined, size: 19),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9)),
                ),
              ),
              const SizedBox(height: 17),
              const Text('Password',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 7),
              TextField(
                controller: passwordController,
                obscureText: hidePassword,
                decoration: InputDecoration(
                  hintText: '••••••••',
                  prefixIcon: const Icon(Icons.lock_outline, size: 19),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => hidePassword = !hidePassword),
                    icon: Icon(
                      hidePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 19,
                    ),
                  ),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9)),
                ),
              ),
              const SizedBox(height: 7),
              GestureDetector(
                onTap: _forgotPassword,
                child: const Text('Forgot Password?',
                    style: TextStyle(color: green, fontSize: 12)),
              ),
              const SizedBox(height: 45),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: loading ? null : () => _submit(signUp: false),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                  child: loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Login',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Don't have an account? ",
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    GestureDetector(
                      onTap: loading ? null : () => _submit(signUp: true),
                      child: const Text('Sign up',
                          style: TextStyle(
                              color: green,
                              fontWeight: FontWeight.bold,
                              fontSize: 12)),
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

class MainNavigation extends StatefulWidget {
  final int initialIndex;
  const MainNavigation({super.key, this.initialIndex = 0});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  late int currentIndex;
  final pages = const [
    HomeScreen(),
    MapScreen(),
    BookingsScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: currentIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        backgroundColor: Colors.white,
        indicatorColor: lightGreen,
        height: 68,
        onDestinationSelected: (i) => setState(() => currentIndex = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: green),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map, color: green),
              label: 'Map'),
          NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note, color: green),
              label: 'Bookings'),
          NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person, color: green),
              label: 'Profile'),
        ],
      ),
    );
  }
}

class GreetingText extends StatelessWidget {
  const GreetingText({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final fallback = (user?.email ?? 'User').split('@').first;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userDoc()?.snapshots().handleError((_) {}),
      builder: (context, snap) {
        final saved = (snap.data?.data()?['name'] as String?)?.trim();
        final name = (saved == null || saved.isEmpty) ? fallback : saved;
        return Text('Hello, $name 👋',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold));
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final totalSpots =
        parkingData.values.fold<int>(0, (sum, l) => sum + l.length);

    return SafeArea(
      child: StreamBuilder<Set<String>>(
        stream: occupiedStream(),
        builder: (context, snap) {
          final occupied = snap.data ?? <String>{};
          int availableIn(String p) =>
              parkingData[p]!.where((s) => !occupied.contains(s['name'])).length;
          final totalAvailable =
              parkingData.keys.fold<int>(0, (sum, p) => sum + availableIn(p));

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GreetingText(),
                    Icon(Icons.notifications_none, size: 22),
                  ],
                ),
                const SizedBox(height: 15),
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Search Location',
                    hintStyle:
                        const TextStyle(fontSize: 13, color: Colors.grey),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(17),
                  decoration: BoxDecoration(
                    color: lightGreen,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Available',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold)),
                          const Text('spots',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 7),
                          Text('$totalAvailable out of $totalSpots',
                              style: const TextStyle(
                                  fontSize: 21, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Icon(Icons.directions_car, size: 55, color: green),
                    ],
                  ),
                ),
                const SizedBox(height: 21),
                const Text('Near you',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 9),
                for (final p in parkingData.keys)
                  _card(context, p, '${availableIn(p)} Available',
                      parkingDistance[p] ?? ''),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, String name, String available,
      String distance) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: const Icon(Icons.local_parking, color: green, size: 24),
        title: Text(name,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(available,
            style: const TextStyle(fontSize: 11, color: green)),
        trailing: Text(distance,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ParkingListScreen(parkingName: name)),
        ),
      ),
    );
  }
}

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<Set<String>>(
        stream: occupiedStream(),
        builder: (context, snap) {
          final occupied = snap.data ?? <String>{};
          final availableUni = parkingData['University Parking']!
              .where((s) => !occupied.contains(s['name']))
              .length;

          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 14, 18, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Parking Map',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE9E9E9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CustomPaint(
                        painter: MapPainter(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Positioned(
                      left: 25,
                      bottom: 15,
                      right: 25,
                      child: Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 8,
                              color: Colors.black.withValues(alpha: 0.12),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                _dot(green),
                                const Text('Available',
                                    style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 12),
                                _dot(Colors.red),
                                const Text('Occupied',
                                    style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 12),
                                _dot(Colors.grey),
                                const Text('Unknown',
                                    style: TextStyle(fontSize: 10)),
                              ],
                            ),
                            const Divider(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('University Parking',
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12)),
                                      Text('$availableUni Available',
                                          style: const TextStyle(
                                              color: green, fontSize: 10)),
                                    ],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const ParkingListScreen(
                                          parkingName: 'University Parking'),
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: green,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(62, 32),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: const Text('View',
                                      style: TextStyle(fontSize: 11)),
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
            ],
          );
        },
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 7,
        height: 7,
        margin: const EdgeInsets.only(right: 3),
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );
}

class MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 35;
    final line = Paint()
      ..color = const Color(0xFFD0D0D0)
      ..strokeWidth = 2;
    final roads = [
      [Offset(0, size.height * .28), Offset(size.width, size.height * .12)],
      [Offset(0, size.height * .72), Offset(size.width, size.height * .58)],
      [Offset(size.width * .35, 0), Offset(size.width * .55, size.height)],
    ];
    for (final r in roads) {
      canvas.drawLine(r[0], r[1], road);
    }
    for (final r in roads) {
      canvas.drawLine(r[0], r[1], line);
    }
    _m(canvas, Offset(size.width * .28, size.height * .25), green);
    _m(canvas, Offset(size.width * .65, size.height * .32), Colors.red);
    _m(canvas, Offset(size.width * .48, size.height * .53), Colors.red);
    _m(canvas, Offset(size.width * .76, size.height * .63), Colors.grey);
    _m(canvas, Offset(size.width * .25, size.height * .76), Colors.red);
  }

  void _m(Canvas canvas, Offset p, Color c) {
    canvas.drawCircle(p, 7, Paint()..color = c);
    canvas.drawCircle(p, 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(CustomPainter old) => false;
}

class ParkingListScreen extends StatelessWidget {
  final String parkingName;
  const ParkingListScreen({super.key, required this.parkingName});

  @override
  Widget build(BuildContext context) {
    final spots = parkingData[parkingName] ?? parkingData.values.first;
    return Scaffold(
      appBar: AppBar(
        title: Text(parkingName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      body: StreamBuilder<Set<String>>(
        stream: occupiedStream(),
        builder: (context, snap) {
          final occupied = snap.data ?? <String>{};
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              for (final spot in spots)
                Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: ListTile(
                    title: Text(spot['name']!,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      occupied.contains(spot['name'])
                          ? 'Occupied'
                          : 'Available',
                      style: TextStyle(
                        fontSize: 11,
                        color: occupied.contains(spot['name'])
                            ? Colors.red
                            : green,
                      ),
                    ),
                    trailing: Text(spot['distance']!,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SpotDetailsScreen(
                          spotName: spot['name']!,
                          parkingName: parkingName,
                          distance: spot['distance']!,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SpotDetailsScreen extends StatefulWidget {
  final String spotName;
  final String parkingName;
  final String distance;
  const SpotDetailsScreen({
    super.key,
    required this.spotName,
    required this.parkingName,
    required this.distance,
  });

  @override
  State<SpotDetailsScreen> createState() => _SpotDetailsScreenState();
}

class _SpotDetailsScreenState extends State<SpotDetailsScreen> {
  bool busy = false;
  late final Stream<Set<String>> _occupied = occupiedStream();
  late final Stream<ParkingSession?> _session = activeSessionStream();

  Future<void> _checkIn() async {
    setState(() => busy = true);
    final error = await checkInSpot(
        spotName: widget.spotName, parkingName: widget.parkingName);
    if (!mounted) return;
    setState(() => busy = false);
    if (error != null) {
      showMsg(context, error, error: true);
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final q = await sessionsCol()
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    if (!mounted) return;
    final session = q.docs.isNotEmpty
        ? _toSession(q.docs.first)
        : ParkingSession(
            id: '',
            spotName: widget.spotName,
            parkingName: widget.parkingName,
            start: DateTime.now());
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => CheckInScreen(session: session)));
  }

  Widget _row(String t, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(t,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(v, style: const TextStyle(fontSize: 15)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final spotName = widget.spotName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spot Details',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<Set<String>>(
        stream: _occupied,
        builder: (context, snap) {
          final isOccupied = (snap.data ?? <String>{}).contains(spotName);
          return StreamBuilder<ParkingSession?>(
            stream: _session,
            builder: (context, sessSnap) {
              final mine = sessSnap.data?.spotName == spotName;
              return Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isOccupied ? Colors.grey.shade600 : green,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(spotName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold)),
                          Text(widget.parkingName,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isOccupied ? 'Occupied' : 'Available',
                              style: TextStyle(
                                color: isOccupied ? Colors.red : green,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      height: 125,
                      decoration: BoxDecoration(
                        color: lightGreen,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Center(
                          child: Icon(Icons.directions_car,
                              color: green, size: 75)),
                    ),
                    const SizedBox(height: 8),
                    _row('Distance', widget.distance),
                    const Divider(height: 1),
                    _row('Price', '2 SAR / hour'),
                    const Divider(height: 1),
                    _row('Operating Hours', '24/7'),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 52,
                            child: OutlinedButton(
                              onPressed:
                                  (isOccupied || busy) ? null : _checkIn,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: green,
                                side: BorderSide(
                                    color: isOccupied ? Colors.grey : green),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: green))
                                  : Text(mine ? 'Checked-in' : 'Check-in',
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 52,
                            child: ElevatedButton(
                              onPressed: () => showMsg(
                                  context, 'Navigation to $spotName started.'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: green,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text('Navigate',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class CheckInScreen extends StatelessWidget {
  final ParkingSession session;
  const CheckInScreen({super.key, required this.session});

  Widget _item(String t, String v) => Column(
        children: [
          Text(t, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 3),
          Text(v,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      );

  void _home(BuildContext context, int index) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => MainNavigation(initialIndex: index)),
      (r) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const CircleAvatar(
                radius: 34,
                backgroundColor: green,
                child: Icon(Icons.check, color: Colors.white, size: 42),
              ),
              const SizedBox(height: 20),
              const Text('Check-in Successful!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('You are parked at',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 7),
              Text(session.spotName,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _item('Start time', formatTime(session.start)),
                    _item('Date', formatDate(session.start)),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => _home(context, 0),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Done',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _home(context, 2),
                child: const Text('View my booking',
                    style: TextStyle(color: green, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  late final Stream<ParkingSession?> _stream = activeSessionStream();

  void _confirmCheckout(BuildContext context, ParkingSession session) {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Check-out'),
        content: const Text('Are you sure you want to check-out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: green, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(d);
              final elapsed = DateTime.now().difference(session.start);
              final safe = elapsed.isNegative ? Duration.zero : elapsed;
              final cost = calculateCost(safe);
              final error = await checkOutSession(session, safe, cost);
              if (!context.mounted) return;
              if (error != null) {
                showMsg(context, error, error: true);
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => CheckOutScreen(duration: safe, cost: cost)),
              );
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
        decoration: BoxDecoration(
            color: greyBg, borderRadius: BorderRadius.circular(12)),
        child: const Column(
          children: [
            Icon(Icons.local_parking, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('No active parking',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 4),
            Text('Choose a spot and check-in to start.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );

  Widget _sessionCard(BuildContext context, ParkingSession s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(s.spotName,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: lightGreen,
                              borderRadius: BorderRadius.circular(5)),
                          child: const Text('Active',
                              style: TextStyle(
                                  color: green,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    Text(s.parkingName,
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LiveStats(session: s),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _confirmCheckout(context, s),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    minimumSize: const Size(double.infinity, 42),
                  ),
                  child:
                      const Text('Check-out', style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => showMsg(context, 'Navigation started.'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 42),
                  ),
                  child: const Text('Navigate', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
        child: StreamBuilder<ParkingSession?>(
          stream: _stream,
          builder: (context, snap) {
            final session = snap.data;
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(
                    child: Text('Bookings',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 25),
                  if (snap.connectionState == ConnectionState.waiting)
                    const Center(child: CircularProgressIndicator(color: green))
                  else if (session == null)
                    _empty()
                  else
                    _sessionCard(context, session),
                  const SizedBox(height: 14),
                  if (session != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBE8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.notifications_none,
                              size: 18, color: Colors.orange),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Don't forget to check-out when you leave.",
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class LiveStats extends StatefulWidget {
  final ParkingSession session;
  const LiveStats({super.key, required this.session});

  @override
  State<LiveStats> createState() => _LiveStatsState();
}

class _LiveStatsState extends State<LiveStats> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _info(String t, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(
            v,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.session.start);
    final safe = elapsed.isNegative ? Duration.zero : elapsed;
    final cost = calculateCost(safe);
    return Row(
      children: [
        Expanded(child: _info('Start time', formatTime(widget.session.start))),
        Expanded(child: _info('Duration', formatDuration(safe))),
        Expanded(
            child: _info('Cost so far', '${cost.toStringAsFixed(2)} SAR')),
      ],
    );
  }
}

class CheckOutScreen extends StatelessWidget {
  final Duration duration;
  final double cost;
  const CheckOutScreen({super.key, required this.duration, required this.cost});

  void _home(BuildContext context, int index) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => MainNavigation(initialIndex: index)),
      (r) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const CircleAvatar(
                radius: 34,
                backgroundColor: green,
                child: Icon(Icons.check, color: Colors.white, size: 42),
              ),
              const SizedBox(height: 20),
              const Text('Check-out Successful!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 7),
              const Text('Thank you for using SmartPark.',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Total Duration',
                            style:
                                TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 5),
                        Text(formatDuration(duration),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Total cost',
                            style:
                                TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 5),
                        Text('${cost.toStringAsFixed(2)} SAR',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => _home(context, 0),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Done',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _home(context, 2),
                child: const Text('Back to Bookings',
                    style: TextStyle(color: green, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _edit(BuildContext context, String name, String phone,
      String location) async {
    final nameC = TextEditingController(text: name);
    final phoneC = TextEditingController(text: phone);
    final locC = TextEditingController(text: location);

    await showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Edit profile'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: nameC,
                  decoration: const InputDecoration(
                      labelText: 'Name', prefixIcon: Icon(Icons.person_outline))),
              const SizedBox(height: 10),
              TextField(
                  controller: phoneC,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone',
                      hintText: '+966 5X XXX XXXX',
                      prefixIcon: Icon(Icons.phone_outlined))),
              const SizedBox(height: 10),
              TextField(
                  controller: locC,
                  decoration: const InputDecoration(
                      labelText: 'Location',
                      hintText: 'City, Country',
                      prefixIcon: Icon(Icons.location_on_outlined))),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: green, foregroundColor: Colors.white),
            onPressed: () async {
              try {
                await userDoc()?.set({
                  'name': nameC.text.trim(),
                  'phone': phoneC.text.trim(),
                  'location': locC.text.trim(),
                }, SetOptions(merge: true));
                if (d.mounted) Navigator.pop(d);
                if (context.mounted) showMsg(context, 'Profile saved.');
              } catch (e) {
                if (context.mounted) {
                  showMsg(context, 'Could not save. Check rules.', error: true);
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _btn(BuildContext context, IconData icon, String text, Widget page) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 7),
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(icon, color: green, size: 19),
            const SizedBox(width: 9),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final fallbackName = email.split('@').first;

    return SafeArea(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userDoc()?.snapshots().handleError((_) {}),
        builder: (context, snap) {
          final data = snap.data?.data() ?? {};
          final savedName = (data['name'] as String?)?.trim() ?? '';
          final name = savedName.isEmpty ? fallbackName : savedName;
          final phone = (data['phone'] as String?)?.trim() ?? '';
          final location = (data['location'] as String?)?.trim() ?? '';

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Profile',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 27,
                      backgroundColor: lightGreen,
                      child: Icon(Icons.person_outline, color: green, size: 29),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(email,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          _edit(context, savedName, phone, location),
                      icon: const Icon(Icons.edit_outlined, color: green),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text('Personal Information',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 7),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                      color: greyBg, borderRadius: BorderRadius.circular(9)),
                  child: Column(
                    children: [
                      _InfoRow(icon: Icons.email_outlined, text: email),
                      const SizedBox(height: 10),
                      _InfoRow(
                          icon: Icons.phone_outlined,
                          text: phone.isEmpty ? 'Add your phone number' : phone,
                          empty: phone.isEmpty),
                      const SizedBox(height: 10),
                      _InfoRow(
                          icon: Icons.location_on_outlined,
                          text: location.isEmpty
                              ? 'Add your location'
                              : location,
                          empty: location.isEmpty),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _btn(context, Icons.credit_card_outlined, 'Payment Methods',
                    const PaymentMethodsScreen()),
                _btn(context, Icons.notifications_none, 'Notifications',
                    const NotificationsScreen()),
                _btn(context, Icons.settings_outlined, 'Settings',
                    const SettingsScreen()),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await AuthService.logout();
                      if (!context.mounted) return;
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                    icon: const Icon(Icons.logout, color: Colors.red, size: 18),
                    label: const Text('Logout',
                        style: TextStyle(color: Colors.red, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool empty;
  const _InfoRow({required this.icon, required this.text, this.empty = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: empty ? Colors.grey.shade400 : Colors.grey.shade700,
              fontStyle: empty ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
      ],
    );
  }
}

class PaymentMethodsScreen extends StatelessWidget {
  const PaymentMethodsScreen({super.key});

  Future<void> _addCard(BuildContext context) async {
    final holderC = TextEditingController();
    final last4C = TextEditingController();
    String brand = 'Mada';
    String? error;

    await showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add card'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: brand,
                  decoration: const InputDecoration(labelText: 'Card type'),
                  items: const ['Mada', 'Visa', 'Mastercard']
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) => setLocal(() => brand = v ?? 'Mada'),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: holderC,
                    decoration:
                        const InputDecoration(labelText: 'Card holder name')),
                const SizedBox(height: 10),
                TextField(
                  controller: last4C,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  decoration: InputDecoration(
                    labelText: 'Last 4 digits',
                    helperText: 'Only the last 4 digits are stored.',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: green, foregroundColor: Colors.white),
              onPressed: () async {
                final last4 = last4C.text.trim();
                if (!RegExp(r'^\d{4}$').hasMatch(last4)) {
                  setLocal(() => error = 'Enter exactly 4 digits');
                  return;
                }
                if (holderC.text.trim().isEmpty) {
                  showMsg(context, 'Enter the card holder name.', error: true);
                  return;
                }
                try {
                  await userDoc()?.set({
                    'cards': FieldValue.arrayUnion([
                      {
                        'id': DateTime.now().millisecondsSinceEpoch.toString(),
                        'brand': brand,
                        'holder': holderC.text.trim(),
                        'last4': last4,
                      }
                    ]),
                  }, SetOptions(merge: true));
                  if (d.mounted) Navigator.pop(d);
                } catch (e) {
                  if (context.mounted) {
                    showMsg(context, 'Could not save the card.', error: true);
                  }
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, Map<String, dynamic> card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Remove card'),
        content: Text('Remove ${card['brand']} •••• ${card['last4']}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await userDoc()?.set({
      'cards': FieldValue.arrayRemove([card]),
    }, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Methods',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userDoc()?.snapshots().handleError((_) {}),
        builder: (context, snap) {
          final raw = (snap.data?.data()?['cards'] as List?) ?? [];
          final cards =
              raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              if (cards.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  decoration: BoxDecoration(
                      color: greyBg, borderRadius: BorderRadius.circular(12)),
                  child: const Column(
                    children: [
                      Icon(Icons.credit_card_off_outlined,
                          size: 44, color: Colors.grey),
                      SizedBox(height: 10),
                      Text('No saved cards',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              for (final c in cards)
                Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.credit_card, color: green),
                    title: Text('${c['brand']} •••• ${c['last4']}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${c['holder']}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _remove(context, c),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => _addCard(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add card'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Demo only. Real payments need a payment gateway.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          );
        },
      ),
    );
  }
}

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  Future<void> _set(BuildContext context, String key, bool value) async {
    try {
      await userDoc()?.set({
        'settings': {key: value},
      }, SetOptions(merge: true));
    } catch (e) {
      if (context.mounted) {
        showMsg(context, 'Could not save the setting.', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userDoc()?.snapshots().handleError((_) {}),
        builder: (context, snap) {
          final s = Map<String, dynamic>.from(
              (snap.data?.data()?['settings'] as Map?) ?? {});
          bool v(String k) => (s[k] as bool?) ?? true;

          return ListView(
            padding: const EdgeInsets.all(8),
            children: [
              SwitchListTile(
                activeColor: green,
                title: const Text('Check-out reminder'),
                subtitle: const Text('Remind me to check-out when I leave.'),
                value: v('checkoutReminder'),
                onChanged: (x) => _set(context, 'checkoutReminder', x),
              ),
              SwitchListTile(
                activeColor: green,
                title: const Text('Spot availability'),
                subtitle: const Text('Tell me when spots open up nearby.'),
                value: v('availabilityAlerts'),
                onChanged: (x) => _set(context, 'availabilityAlerts', x),
              ),
              SwitchListTile(
                activeColor: green,
                title: const Text('Long parking alert'),
                subtitle: const Text('Alert me if my session is very long.'),
                value: v('longParkingAlert'),
                onChanged: (x) => _set(context, 'longParkingAlert', x),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _reset(BuildContext context) async {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (context.mounted) showMsg(context, 'Reset link sent to $email');
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        showMsg(context, 'Could not send email (${e.code}).', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.email_outlined, color: green),
            title: const Text('Account email'),
            subtitle: Text(email),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_reset, color: green),
            title: const Text('Change password'),
            subtitle: const Text('We will email you a reset link.'),
            onTap: () => _reset(context),
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.payments_outlined, color: green),
            title: Text('Parking price'),
            subtitle: Text('2 SAR per hour'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline, color: green),
            title: const Text('About SmartPark'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'SmartPark',
              applicationVersion: '1.0.0',
              children: const [
                Text('Parking finder app built with Flutter and Firebase.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}