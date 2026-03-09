import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

class BlockchainService {
  // ─── Singleton ───────────────────────────────────────────────────────────────
  BlockchainService._();
  static final BlockchainService instance = BlockchainService._();

  // ─── State ───────────────────────────────────────────────────────────────────
  Web3Client? _client;
  EthPrivateKey? _credentials;
  DeployedContract? _contract;
  bool _initialized = false;

  // ─── Contract ABI ────────────────────────────────────────────────────────────
  // Only the functions we need
  static const String _abi = '''[
    {
      "inputs": [
        {"internalType": "string", "name": "reportId", "type": "string"},
        {"internalType": "string", "name": "reportHash", "type": "string"},
        {"internalType": "string", "name": "incidentType", "type": "string"}
      ],
      "name": "submitReport",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {"internalType": "string", "name": "reportId", "type": "string"},
        {"internalType": "string", "name": "reportHash", "type": "string"}
      ],
      "name": "verifyReport",
      "outputs": [{"internalType": "bool", "name": "", "type": "bool"}],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {"internalType": "string", "name": "reportId", "type": "string"}
      ],
      "name": "getReport",
      "outputs": [
        {"internalType": "string", "name": "", "type": "string"},
        {"internalType": "string", "name": "", "type": "string"},
        {"internalType": "uint256", "name": "", "type": "uint256"}
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "getTotalReports",
      "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "owner",
      "outputs": [{"internalType": "address", "name": "", "type": "address"}],
      "stateMutability": "view",
      "type": "function"
    }
  ]''';

  // ─── Initialize ──────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Load credentials from .env
      final rpcUrl =
          dotenv.env['SEPOLIA_RPC_URL'] ??
          'https://ethereum-sepolia-rpc.publicnode.com';
      final privateKey = dotenv.env['WALLET_PRIVATE_KEY'] ?? '';
      final contractAddress = dotenv.env['CONTRACT_ADDRESS'] ?? '';

      if (privateKey.isEmpty || contractAddress.isEmpty) {
        debugPrint('BlockchainService: Missing credentials in .env');
        return;
      }

      // Connect to Sepolia
      _client = Web3Client(rpcUrl, http.Client());

      // Load wallet
      _credentials = EthPrivateKey.fromHex(privateKey);

      // Load contract
      _contract = DeployedContract(
        ContractAbi.fromJson(_abi, 'CityGuardReports'),
        EthereumAddress.fromHex(contractAddress),
      );

      _initialized = true;
      debugPrint('BlockchainService: ✅ Connected to Sepolia blockchain');
    } catch (e) {
      debugPrint('BlockchainService: ❌ Init failed — $e');
    }
  }

  // ─── Generate Hash ───────────────────────────────────────────────────────────

  /// Generate SHA-256 hash of report data
  /// This hash proves the report content was never tampered with
  String generateReportHash({
    required String reportId,
    required String userId,
    required String type,
    required String description,
    required String timestamp,
  }) {
    final data = '$reportId|$userId|$type|$description|$timestamp';
    final bytes = utf8.encode(data);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  // ─── Submit Report Hash ──────────────────────────────────────────────────────

  /// Save report hash to blockchain
  /// Called after report is saved to Firestore
  Future<String?> submitReportHash({
    required String reportId,
    required String reportHash,
    required String incidentType,
  }) async {
    if (!_initialized) await initialize();
    if (_client == null || _contract == null || _credentials == null) {
      debugPrint('BlockchainService: Not initialized');
      return null;
    }

    try {
      final function = _contract!.function('submitReport');

      final txHash = await _client!.sendTransaction(
        _credentials!,
        Transaction.callContract(
          contract: _contract!,
          function: function,
          parameters: [reportId, reportHash, incidentType],
          // ✅ Gas optimized — sufficient for string storage operations
          maxGas: 500000,
        ),
        chainId: 11155111, // Sepolia chain ID
      );

      debugPrint('BlockchainService: ✅ Report hash saved — tx: $txHash');
      return txHash;
    } catch (e) {
      debugPrint('BlockchainService: ❌ Submit failed — $e');
      return null;
    }
  }

  // ─── Verify Report ───────────────────────────────────────────────────────────

  /// Verify report hash against blockchain
  /// Returns true if report was not tampered with
  Future<bool> verifyReport({
    required String reportId,
    required String reportHash,
  }) async {
    if (!_initialized) await initialize();
    if (_client == null || _contract == null) return false;

    try {
      final function = _contract!.function('verifyReport');

      final result = await _client!.call(
        contract: _contract!,
        function: function,
        params: [reportId, reportHash],
      );

      final isValid = result[0] as bool;
      debugPrint('BlockchainService: Verify result — $isValid');
      return isValid;
    } catch (e) {
      debugPrint('BlockchainService: ❌ Verify failed — $e');
      return false;
    }
  }

  // ─── Get Total Reports ───────────────────────────────────────────────────────

  /// Get total number of reports stored on blockchain
  Future<int> getTotalReports() async {
    if (!_initialized) await initialize();
    if (_client == null || _contract == null) return 0;

    try {
      final function = _contract!.function('getTotalReports');

      final result = await _client!.call(
        contract: _contract!,
        function: function,
        params: [],
      );

      final total = (result[0] as BigInt).toInt();
      debugPrint('BlockchainService: Total reports on chain — $total');
      return total;
    } catch (e) {
      debugPrint('BlockchainService: ❌ Get total failed — $e');
      return 0;
    }
  }

  // ─── Dispose ─────────────────────────────────────────────────────────────────

  void dispose() {
    _client?.dispose();
    _initialized = false;
  }
}
