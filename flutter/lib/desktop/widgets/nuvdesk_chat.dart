// NuvDesk (P04): chat com o suporte, dentro da janela do NuvDesk.
//
// Fechado, e so o botao "Fale com o Suporte". Aberto, mostra a conversa e a
// janela cresce (a home recalcula o tamanho pelo conteudo do painel esquerdo).
//
// Mensagens chegam na hora por "long polling": POST /agent/chat/sync fica
// parado na API ate chegar novidade (ou 25s). Quando o tecnico escreve, o chat
// abre sozinho e a janela vem pra frente. Com a janela FECHADA, quem abre e a
// vigia da bandeja (src/tray.rs).
//
// Credencial: a mesma do heartbeat, gravada pelo instalador em
// %ProgramData%\NuvDesk\state.json. Sem ela (NuvDesk instalado sem o nosso
// instalador), o chat nao aparece.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';

const _azul = Color(0xFF162891);
const _azulClaro = Color(0xFFE3EFFA);
const _laranja = Color(0xFFF26422);
const _imagemMax = 5 * 1024 * 1024;

class _Credencial {
  final String api;
  final String maquina;
  final String token;
  _Credencial(this.api, this.maquina, this.token);

  static _Credencial? ler() {
    try {
      final base = Platform.environment['ProgramData'];
      if (base == null) return null;
      final arquivo = File('$base\\NuvDesk\\state.json');
      if (!arquivo.existsSync()) return null;
      var texto = arquivo.readAsStringSync();
      // O PowerShell grava com BOM as vezes.
      if (texto.isNotEmpty && texto.codeUnitAt(0) == 0xFEFF) texto = texto.substring(1);
      final v = jsonDecode(texto) as Map<String, dynamic>;
      final api = (v['api'] ?? '').toString().replaceAll(RegExp(r'/+$'), '');
      final maquina = (v['machine_id'] ?? '').toString();
      final token = (v['agent_token'] ?? '').toString();
      if (api.isEmpty || maquina.isEmpty || token.isEmpty) return null;
      return _Credencial(api, maquina, token);
    } catch (_) {
      return null;
    }
  }
}

class _Mensagem {
  final int id;
  final String remetente; // client | operator | system
  final String texto;
  final String? imagemId;
  final bool lida;
  final DateTime criada;
  final String autor;

  _Mensagem.json(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        remetente = (j['sender'] ?? '').toString(),
        texto = (j['body'] ?? '').toString(),
        imagemId = j['image_id']?.toString(),
        lida = j['read_at'] != null,
        criada = DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
        autor = (j['autor'] ?? '').toString();
}

class NuvDeskChat extends StatefulWidget {
  /// Chamado quando o chat abre/fecha ou muda de altura: a home ajusta a janela.
  final VoidCallback onMudouTamanho;
  const NuvDeskChat({Key? key, required this.onMudouTamanho}) : super(key: key);

  @override
  State<NuvDeskChat> createState() => _NuvDeskChatState();
}

class _NuvDeskChatState extends State<NuvDeskChat> {
  _Credencial? _cred;
  final _cliente = http.Client();
  final _texto = TextEditingController();
  final _rolagem = ScrollController();
  final _foco = FocusNode();

  bool _vivo = true;
  bool _aberto = false;
  bool _enviando = false;
  String _erro = '';
  String? _conversaId;
  String _status = '';
  String _atendente = '';
  int _naoLidas = 0;
  int _ultimaAvisada = 0;
  final List<_Mensagem> _mensagens = [];
  final Map<String, Future<Uint8List?>> _imagens = {};

  @override
  void initState() {
    super.initState();
    _cred = _Credencial.ler();
    if (_cred != null) _laco();
  }

  @override
  void dispose() {
    _vivo = false;
    _cliente.close();
    _texto.dispose();
    _rolagem.dispose();
    _foco.dispose();
    super.dispose();
  }

  Map<String, dynamic> _base() => {
        'machine_id': _cred!.maquina,
        'agent_token': _cred!.token,
        'windows_user': Platform.environment['USERNAME'] ?? '',
      };

  Future<Map<String, dynamic>> _post(String caminho, Map<String, dynamic> corpo,
      {Duration limite = const Duration(seconds: 20)}) async {
    final r = await _cliente
        .post(Uri.parse('${_cred!.api}/api/v1/agent/chat/$caminho'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({..._base(), ...corpo}))
        .timeout(limite);
    // A API nao manda charset: decodifica UTF-8 na mao (acentos).
    final texto = utf8.decode(r.bodyBytes);
    final json = texto.isEmpty ? <String, dynamic>{} : jsonDecode(texto) as Map<String, dynamic>;
    if (r.statusCode >= 400) {
      throw Exception((json['error'] ?? 'falha ao comunicar com o suporte').toString());
    }
    return json;
  }

  Future<void> _laco() async {
    while (_vivo) {
      try {
        final ultimo = _mensagens.isEmpty ? 0 : _mensagens.last.id;
        final r = await _post('sync', {'after_id': ultimo, 'wait': true},
            limite: const Duration(seconds: 40));
        if (!_vivo) return;
        _aplicar(r);
      } catch (_) {
        if (!_vivo) return;
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  void _aplicar(Map<String, dynamic> r) {
    final conversa = r['conversa'] as Map<String, dynamic>?;
    final novas = ((r['mensagens'] as List?) ?? [])
        .map((m) => _Mensagem.json(m as Map<String, dynamic>))
        .toList();
    final id = conversa?['id']?.toString();
    final trocou = id != _conversaId;
    setState(() {
      if (trocou) {
        // Conversa nova (a anterior foi encerrada): recomeca a lista.
        _mensagens.clear();
        _conversaId = id;
      }
      for (final m in novas) {
        final i = _mensagens.indexWhere((x) => x.id == m.id);
        if (i < 0) _mensagens.add(m);
      }
      _status = (conversa?['status'] ?? '').toString();
      _atendente = (conversa?['atendente'] ?? '').toString();
      _naoLidas = (r['nao_lidas'] as num?)?.toInt() ?? 0;
    });
    if (trocou && id != null && novas.isEmpty) {
      // Pediu "depois do id X" de outra conversa: busca desde o inicio.
      _post('sync', {'after_id': 0}).then(_aplicar).catchError((Object _) {});
      return;
    }
    final ultimaNaoLida = (r['ultima_nao_lida_id'] as num?)?.toInt() ?? 0;
    if (ultimaNaoLida > _ultimaAvisada) {
      _ultimaAvisada = ultimaNaoLida;
      // O tecnico escreveu: abre o chat e traz a janela pra frente.
      _abrir(trazerJanela: true);
    } else if (_aberto) {
      _marcarLidas();
    }
    if (novas.isNotEmpty) _rolarProFim();
  }

  void _abrir({bool trazerJanela = false}) {
    if (!_aberto) {
      setState(() => _aberto = true);
      widget.onMudouTamanho();
    }
    if (trazerJanela) {
      windowManager.show();
      windowManager.focus();
    }
    _marcarLidas();
    _rolarProFim();
  }

  void _fechar() {
    setState(() => _aberto = false);
    widget.onMudouTamanho();
  }

  void _marcarLidas() {
    final ultimaDoTecnico = _mensagens.lastWhere((m) => m.remetente == 'operator',
        orElse: () => _Mensagem.json({'id': 0}));
    if (_naoLidas == 0 || ultimaDoTecnico.id == 0) return;
    _post('read', {'up_to_id': ultimaDoTecnico.id}).then((_) {
      if (mounted) setState(() => _naoLidas = 0);
    }).catchError((Object _) {});
  }

  void _rolarProFim() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_rolagem.hasClients) {
        _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
      }
    });
  }

  Future<void> _enviarTexto() async {
    final texto = _texto.text.trim();
    if (texto.isEmpty || _enviando) return;
    setState(() {
      _enviando = true;
      _erro = '';
    });
    try {
      final r = await _post('send', {'body': texto});
      _texto.clear();
      final conversa = r['conversa'] as Map<String, dynamic>?;
      if (conversa != null && conversa['id']?.toString() != _conversaId) {
        // Abriu conversa nova: busca tudo dela.
        _aplicar(await _post('sync', {'after_id': 0}));
      } else {
        final ultimo = _mensagens.isEmpty ? 0 : _mensagens.last.id;
        _aplicar(await _post('sync', {'after_id': ultimo}));
      }
    } catch (e) {
      setState(() => _erro = _mensagemErro(e));
    } finally {
      if (mounted) setState(() => _enviando = false);
      _foco.requestFocus();
    }
  }

  Future<void> _enviarImagem() async {
    if (_enviando) return;
    final escolha = await FilePicker.platform.pickFiles(type: FileType.image);
    final caminho = escolha?.files.single.path;
    if (caminho == null) return;
    setState(() {
      _enviando = true;
      _erro = '';
    });
    try {
      final bytes = await File(caminho).readAsBytes();
      if (bytes.length > _imagemMax) {
        throw Exception('imagem maior que 5 MB');
      }
      final r = await _cliente
          .post(Uri.parse('${_cred!.api}/api/v1/agent/chat/imagens'),
              headers: {
                'X-Machine-Id': _cred!.maquina,
                'X-Agent-Token': _cred!.token,
                'X-Windows-User': Platform.environment['USERNAME'] ?? '',
              },
              body: bytes)
          .timeout(const Duration(seconds: 60));
      if (r.statusCode >= 400) {
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        throw Exception((j['error'] ?? 'imagem nao enviada').toString());
      }
      final ultimo = _mensagens.isEmpty ? 0 : _mensagens.last.id;
      _aplicar(await _post('sync', {'after_id': ultimo}));
    } catch (e) {
      setState(() => _erro = _mensagemErro(e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  String _mensagemErro(Object e) {
    final t = e.toString().replaceFirst('Exception: ', '');
    if (e is TimeoutException || e is SocketException || t.contains('SocketException')) {
      return 'Sem conexão com o suporte. Verifique a internet.';
    }
    const traducoes = {
      'imagem maior que 5 MB': 'A imagem passa de 5 MB.',
      'formato nao suportado; envie PNG, JPG, GIF ou WEBP': 'Envie PNG, JPG, GIF ou WEBP.',
      'mensagem vazia ou longa demais': 'Mensagem vazia ou longa demais.',
    };
    return traducoes[t] ?? 'Não foi possível enviar. Tente de novo.';
  }

  Future<Uint8List?> _baixarImagem(String id) {
    return _imagens.putIfAbsent(id, () async {
      try {
        final r = await _cliente.get(Uri.parse('${_cred!.api}/api/v1/agent/chat/imagens/$id'), headers: {
          'X-Machine-Id': _cred!.maquina,
          'X-Agent-Token': _cred!.token,
        }).timeout(const Duration(seconds: 30));
        return r.statusCode == 200 ? r.bodyBytes : null;
      } catch (_) {
        _imagens.remove(id);
        return null;
      }
    });
  }

  String _hora(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_cred == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: _aberto ? _painel(context) : _botao(),
    );
  }

  Widget _botao() {
    return Material(
      color: _azul,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _abrir(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.chat_bubble_outline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Fale com o Suporte',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              if (_naoLidas > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: _laranja, borderRadius: BorderRadius.circular(10)),
                  child: Text('$_naoLidas',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _painel(BuildContext context) {
    final encerrada = _status == 'closed';
    final linhaStatus = _conversaId == null
        ? 'Escreva sua dúvida que um técnico responde por aqui.'
        : encerrada
            ? 'Atendimento encerrado. Escreva para abrir outro.'
            : _atendente.isNotEmpty
                ? 'Em atendimento com $_atendente'
                : 'Aguardando um técnico...';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD9E0E8)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: const BoxDecoration(
              color: _azul,
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Suporte',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      Text(linhaStatus,
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Minimizar conversa',
                  icon: const Icon(Icons.expand_more, color: Colors.white),
                  onPressed: _fechar,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 300,
            child: Container(
              color: const Color(0xFFF5F7FA),
              child: _mensagens.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Nenhuma mensagem ainda.',
                            style: TextStyle(color: Colors.black45, fontSize: 12)),
                      ),
                    )
                  : ListView.builder(
                      controller: _rolagem,
                      padding: const EdgeInsets.all(8),
                      itemCount: _mensagens.length,
                      itemBuilder: (_, i) => _bolha(_mensagens[i]),
                    ),
            ),
          ),
          if (_erro.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: const Color(0xFFFEE4E2),
              child: Text(_erro, style: const TextStyle(color: Color(0xFFB42318), fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Enviar imagem',
                  icon: const Icon(Icons.image_outlined, size: 20),
                  onPressed: _enviando ? null : _enviarImagem,
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, evento) {
                      // Enter envia; Shift+Enter quebra linha.
                      if (evento is KeyDownEvent &&
                          (evento.logicalKey == LogicalKeyboardKey.enter ||
                              evento.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        _enviarTexto();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _texto,
                      focusNode: _foco,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 4000,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: 'Escreva uma mensagem',
                        counterText: '',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Enviar',
                  icon: const Icon(Icons.send, size: 20, color: _azul),
                  onPressed: _enviando ? null : _enviarTexto,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bolha(_Mensagem m) {
    if (m.remetente == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFE9EDF2), borderRadius: BorderRadius.circular(10)),
            child: Text('${m.texto} · ${_hora(m.criada)}',
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ),
        ),
      );
    }
    final meu = m.remetente == 'client';
    return Align(
      alignment: meu ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: meu ? _azulClaro : Colors.white,
          border: Border.all(color: const Color(0xFFD9E0E8)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!meu && m.autor.isNotEmpty)
              Text(m.autor,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _azul)),
            if (m.imagemId != null) _imagem(m.imagemId!),
            if (m.texto.isNotEmpty) SelectableText(m.texto, style: const TextStyle(fontSize: 13)),
            Align(
              alignment: Alignment.centerRight,
              child: Text(_hora(m.criada), style: const TextStyle(fontSize: 10, color: Colors.black45)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imagem(String id) {
    return FutureBuilder<Uint8List?>(
      future: _baixarImagem(id),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
              width: 120, height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final bytes = snap.data;
        if (bytes == null) {
          return const Text('Imagem indisponível',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.black45));
        }
        return GestureDetector(
          onTap: () => showDialog(
            context: context,
            builder: (_) => Dialog(
              child: InkWell(
                onTap: () => Navigator.of(context).pop(),
                child: InteractiveViewer(child: Image.memory(bytes)),
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(bytes, height: 140, fit: BoxFit.contain),
          ),
        );
      },
    );
  }
}
