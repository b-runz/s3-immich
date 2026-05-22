import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/providers/background_sync.provider.dart';
import 'package:s3mmich/services/s3/s3_config.dart';
import 'package:s3mmich/services/s3/s3_service_provider.dart';
import 'package:s3mmich/routing/router.dart';

@RoutePage()
class S3SetupPage extends ConsumerStatefulWidget {
  const S3SetupPage({super.key});

  @override
  ConsumerState<S3SetupPage> createState() => _S3SetupPageState();
}

class _S3SetupPageState extends ConsumerState<S3SetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _endpointCtrl = TextEditingController();
  final _bucketCtrl = TextEditingController();
  final _regionCtrl = TextEditingController(text: 'us-east-1');
  final _accessKeyCtrl = TextEditingController();
  final _secretKeyCtrl = TextEditingController();
  final _prefixCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _endpointCtrl,
      _bucketCtrl,
      _regionCtrl,
      _accessKeyCtrl,
      _secretKeyCtrl,
      _prefixCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rawEndpoint = _endpointCtrl.text.trim();
      // Strip leading https:// or http:// — S3Config expects hostname only
      final endpoint =
          rawEndpoint.replaceFirst(RegExp(r'^https?://'), '');
      final config = S3Config(
        endpoint: endpoint,
        bucket: _bucketCtrl.text.trim(),
        region: _regionCtrl.text.trim(),
        accessKey: _accessKeyCtrl.text.trim(),
        secretKey: _secretKeyCtrl.text.trim(),
        prefix: _prefixCtrl.text.trim().isEmpty
            ? null
            : _prefixCtrl.text.trim(),
        useSSL: true,
      );
      await ref.read(s3ServiceProvider).configure(config);
      if (mounted) {
        unawaited(context.router.replaceAll([const TabShellRoute()]));
        unawaited(ref.read(backgroundSyncProvider).syncLocal(full: true));
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to S3')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(
              'Endpoint',
              _endpointCtrl,
              hint: 's3.nl-ams.scw.cloud',
              required: true,
            ),
            _field('Bucket', _bucketCtrl, required: true),
            _field('Region', _regionCtrl, required: true),
            _field('Access Key', _accessKeyCtrl, required: true),
            _field(
              'Secret Key',
              _secretKeyCtrl,
              required: true,
              obscure: true,
            ),
            _field('Prefix (optional)', _prefixCtrl),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool required = false,
    bool obscure = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: ctrl,
          decoration:
              InputDecoration(labelText: label, hintText: hint),
          obscureText: obscure,
          validator: required
              ? (v) => (v == null || v.trim().isEmpty)
                  ? '$label is required'
                  : null
              : null,
        ),
      );
}
