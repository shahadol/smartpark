import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCAlTox-qQlQhBy-93aoi3DmIP6sDY5d3A',
    appId: '1:892849356127:web:eaa23fe28bb537d4b80aea',
    messagingSenderId: '892849356127',
    projectId: 'smartpark-aae50',
    authDomain: 'smartpark-aae50.firebaseapp.com',
    storageBucket: 'smartpark-aae50.firebasestorage.app',
  );

  static FirebaseOptions get currentPlatform => web;
}