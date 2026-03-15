import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';

class ConnectivityService extends GetxService {
  static ConnectivityService get instance => Get.find();

  final RxBool isConnected = true.obs;
  late StreamSubscription _subscription;

  @override
  void onInit() {
    super.onInit();
    _checkInitial();
    _subscription = Connectivity().onConnectivityChanged.listen(_updateStatus);
  }

  Future<void> _checkInitial() async {
    final result = await Connectivity().checkConnectivity();
    _updateStatus(result);
  }

  void _updateStatus(List<ConnectivityResult> results) {
    isConnected.value = results.any((r) => r != ConnectivityResult.none);
  }

  @override
  void onClose() {
    _subscription.cancel();
    super.onClose();
  }
}
