// NuvDesk (Android): pareamento com o painel por codigo de 6 digitos.
//
// O tecnico gera o codigo em Dispositivos > Parear celular; o cliente digita
// aqui e o aparelho entra na lista do painel com o nome e o grupo escolhidos.
// O app nao leva o token de provisionamento (download livre), por isso o codigo.
// API: POST /api/v1/agent/pair (apps/api/cmd/nuvdesk-api/pareamento.go).
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../models/platform_model.dart';

const _kApi = 'https://api.nuvdeskapp.com.br';
const _kOpcaoPareado = 'nuvdesk-pareado';
// Vem do build (--dart-define), a mesma de NUVDESK_ANDROID_VERSION da CI.
const _kVersaoApp = String.fromEnvironment('NUVDESK_ANDROID_VERSION');

class NuvdeskParearCard extends StatefulWidget {
  const NuvdeskParearCard({Key? key}) : super(key: key);

  @override
  State<NuvdeskParearCard> createState() => _NuvdeskParearCardState();
}

class _NuvdeskParearCardState extends State<NuvdeskParearCard> {
  String _pareadoComo = '';

  @override
  void initState() {
    super.initState();
    _pareadoComo = bind.mainGetLocalOption(key: _kOpcaoPareado);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _pareadoComo.isNotEmpty
          ? Row(children: [
              const Icon(Icons.verified, color: Colors.green),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Pareado com o suporte como "$_pareadoComo".'),
              ),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Aparelho da sua empresa?',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                  'Se o suporte passou um código de 6 dígitos, pareie este '
                  'celular para ele aparecer no painel da Nuvsoft.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Parear com o suporte'),
                onPressed: _abrirDialogo,
              ),
            ]),
    );
  }

  Future<void> _abrirDialogo() async {
    final nome = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoCodigo(),
    );
    if (nome == null || !mounted) return;
    await bind.mainSetLocalOption(key: _kOpcaoPareado, value: nome);
    setState(() => _pareadoComo = nome);
  }
}

class _DialogoCodigo extends StatefulWidget {
  const _DialogoCodigo();

  @override
  State<_DialogoCodigo> createState() => _DialogoCodigoState();
}

class _DialogoCodigoState extends State<_DialogoCodigo> {
  final _codigo = TextEditingController();
  bool _enviando = false;
  String _erro = '';

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final codigo = _codigo.text.replaceAll(RegExp(r'\D'), '');
    if (codigo.length != 6) {
      setState(() => _erro = 'Digite os 6 números do código.');
      return;
    }
    setState(() {
      _enviando = true;
      _erro = '';
    });
    try {
      final id = await bind.mainGetMyId();
      var modelo = '';
      var android = '';
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        modelo = '${info.brand} ${info.model}'.trim();
        android = info.version.release;
      } catch (_) {
        // sem modelo o pareamento funciona do mesmo jeito
      }
      final r = await http
          .post(
            Uri.parse('$_kApi/api/v1/agent/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': codigo,
              'rustdesk_id': id,
              'hostname': modelo,
              'os_version': android,
              'app_version': _kVersaoApp,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (r.statusCode == 200) {
        final nome = (jsonDecode(r.body)['name'] ?? '').toString();
        Navigator.of(context).pop(nome.isEmpty ? 'este celular' : nome);
        return;
      }
      setState(() {
        _enviando = false;
        _erro = r.statusCode == 429
            ? 'Muitas tentativas. Aguarde um minuto e tente de novo.'
            : 'Código inválido ou expirado. Peça um novo ao suporte.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _erro = 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Parear com o suporte'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Digite o código de 6 dígitos que o suporte passou.'),
        const SizedBox(height: 12),
        TextField(
          controller: _codigo,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, letterSpacing: 8),
          decoration: const InputDecoration(hintText: '000000'),
          onSubmitted: (_) => _enviando ? null : _enviar(),
        ),
        if (_erro.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(_erro, style: const TextStyle(color: Colors.red, fontSize: 13)),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _enviando ? null : _enviar,
          child: _enviando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Parear'),
        ),
      ],
    );
  }
}
