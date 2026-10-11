# SmartPark

Parking finder app with check-in / check-out, built with Flutter and Firebase.

Originally a group HCI project (Qassim University, IT215): survey, wireframes,
Figma prototype and Think-Aloud usability testing. This repository is my
individual implementation of that design.

## Features
- Email/password authentication (Firebase Auth)
- Editable profile saved per user (Cloud Firestore)
- Parking categories: University, Mall, Hospital
- Real-time spot status shared across users
- Check-in with transaction (prevents double booking)
- Live timer and cost calculation, check-out with confirmation dialog
- Saved payment methods (demo, last 4 digits only) and notification settings

## Tech
Flutter (web), Firebase Authentication, Cloud Firestore

## Run
flutter pub get
flutter run -d chrome

Note: add your own Firebase config in lib/firebase_options.dart.

## Not implemented yet
Real map and navigation, push notifications, real payments, Android build.

