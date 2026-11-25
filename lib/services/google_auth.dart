import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// "Masuk dengan Google" di HP: lembar pilih akun Google (Credential
/// Manager), hasilnya ID token untuk Client ID web Infois (diberikan server
/// lewat `GET auth/google`). Server memeriksa token itu sendiri.
abstract class GoogleAuth {
  /// ID token Google, atau null bila pengguna menutup lembar pilih akun.
  /// Gagal lain → [GoogleAuthFailure] dengan pesan untuk pengguna.
  Future<String?> idToken({required String serverClientId});
}

class GoogleAuthFailure implements Exception {
  const GoogleAuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Diganti di tes.
final googleAuthProvider = Provider<GoogleAuth>((ref) => PluginGoogleAuth());

class PluginGoogleAuth implements GoogleAuth {
  /// `GoogleSignIn.initialize` hanya boleh dipanggil sekali per aplikasi.
  static Future<void>? _initialized;

  static const _notReady = 'Masuk dengan Google belum bisa dipakai di aplikasi ini. Silakan masuk dengan email dan kata sandi.';

  @override
  Future<String?> idToken({required String serverClientId}) async {
    final signIn = GoogleSignIn.instance;
    try {
      await (_initialized ??= signIn.initialize(serverClientId: serverClientId));
    } catch (error) {
      _initialized = null;
      debugPrint('GoogleSignIn.initialize: $error');
      throw const GoogleAuthFailure(_notReady);
    }
    if (!signIn.supportsAuthenticate()) {
      throw const GoogleAuthFailure(_notReady);
    }
    try {
      final account = await signIn.authenticate(scopeHint: const ['email']);
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw const GoogleAuthFailure('Google tidak mengirim data akun. Coba lagi.');
      }
      return token;
    } on GoogleSignInException catch (error) {
      debugPrint('GoogleSignIn.authenticate: ${error.code} ${error.description}');
      switch (error.code) {
        case GoogleSignInExceptionCode.canceled:
          return null;
        case GoogleSignInExceptionCode.interrupted:
        case GoogleSignInExceptionCode.uiUnavailable:
          throw const GoogleAuthFailure('Masuk dengan Google terputus. Coba lagi.');
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          throw const GoogleAuthFailure(_notReady);
        default:
          throw const GoogleAuthFailure('Belum bisa masuk dengan Google. Pastikan HP terhubung ke internet dan ada akun Google di HP ini, lalu coba lagi.');
      }
    }
  }
}
