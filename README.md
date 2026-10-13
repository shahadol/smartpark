SmartPark
Parking finder app with check-in and check-out, built with Flutter and Firebase.
Course project. This repository is my individual implementation of a team-designed prototype.
Web app: https://smartpark-aae50.web.app/
Android APK: https://github.com/shahadol/smartpark/releases
Features
Email and password authentication (Firebase Authentication)
Editable profile saved per user (Cloud Firestore)
Parking categories: University, Mall, Hospital
Real-time spot status shared across users
Check-in with a transaction that prevents double booking
Live timer and cost calculation, check-out with a confirmation dialog
Saved payment methods (demo only, last 4 digits) and notification settings
Tech
Flutter (Dart), Firebase Authentication, Cloud Firestore. Runs as a web app and an Android app (the Android build was tested on an Android emulator).
Run
Run flutter pub get, then flutter run -d chrome for web, or flutter run for Android (emulator or device).
Note: add your own Firebase config in lib/firebase_options.dart, for example with flutterfire configure.
Not implemented yet
Real map and navigation, push notifications, real payments, iOS build.
