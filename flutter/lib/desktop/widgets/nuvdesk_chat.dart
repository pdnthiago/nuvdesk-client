// NuvDesk: chat com o suporte, dentro da janela do NuvDesk.
//
// P04     chat (long polling na API NuvDesk, credencial do state.json).
// P103    o chat abre num PAINEL A DIREITA, maior; na esquerda fica so o botao.
// P104    Ctrl+V com print (ou arquivo copiado no Explorer) envia o anexo.
// P105    anexos: imagem, documento, certificado digital, audio.
// P106    microfone no lugar do "enviar" quando o campo esta vazio (WhatsApp).
// P108    sons: mensagem do tecnico e conversa nova.
//
// Estado num controlador unico (nuvdeskChat): o botao da esquerda e o painel
// da direita so desenham o que ele tem. A conexao continua viva com o painel
// fechado - e assim que o chat abre sozinho quando o tecnico escreve. Com a
// janela FECHADA, quem abre e a vigia da bandeja (src/tray.rs).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

const _azul = Color(0xFF162891);
const _azulClaro = Color(0xFFE3EFFA);
const _laranja = Color(0xFFF26422);
const _anexoMax = 10 * 1024 * 1024;
const _audioMax = Duration(minutes: 5);

// O que o seletor oferece. A API confere de novo pelo conteudo do arquivo.
const _extensoes = [
  'png', 'jpg', 'jpeg', 'gif', 'webp', //
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods',
  'txt', 'csv', 'xml', 'json', 'ofx', 'zip', '7z', 'rar',
  'pfx', 'p12', 'cer', 'crt', 'der', 'pem',
  'mp3', 'm4a', 'aac', 'ogg', 'wav', 'webm',
];

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

class ChatMensagem {
  final int id;
  final String remetente; // client | operator | system
  final String texto;
  final String? anexoId;
  final String anexoTipo; // imagem | audio | arquivo
  final String anexoNome;
  final int anexoTamanho;
  final DateTime criada;
  final String autor;

  ChatMensagem.json(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        remetente = (j['sender'] ?? '').toString(),
        texto = (j['body'] ?? '').toString(),
        anexoId = j['image_id']?.toString(),
        anexoTipo = (j['anexo_tipo'] ?? '').toString().isEmpty ? 'imagem' : j['anexo_tipo'].toString(),
        anexoNome = (j['anexo_nome'] ?? '').toString(),
        anexoTamanho = (j['anexo_tamanho'] as num?)?.toInt() ?? 0,
        criada = DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
        autor = (j['autor'] ?? '').toString();
}

/// Controlador unico do chat (um por processo).
final nuvdeskChat = NuvDeskChatControle();

class NuvDeskChatControle extends ChangeNotifier {
  _Credencial? _cred;
  final _cliente = http.Client();
  final _som = AudioPlayer();
  final _gravador = AudioRecorder();
  bool _iniciado = false;

  bool get disponivel => _cred != null;
  bool aberto = false;
  bool enviando = false;
  String erro = '';
  String? conversaId;
  String status = '';
  String atendente = '';
  int naoLidas = 0;
  final List<ChatMensagem> mensagens = [];
  final Map<String, Future<Uint8List?>> _anexos = {};

  // Gravacao de audio.
  DateTime? gravandoDesde;
  Timer? _cronometro;

  /// A home ajusta o tamanho da janela quando o painel abre/fecha.
  VoidCallback? aoMudarTamanho;

  int _ultimaAvisada = 0;
  bool _primeiraCarga = true;
  bool _acabeiDeEnviar = false;

  void iniciar() {
    if (_iniciado) return;
    _iniciado = true;
    _cred = _Credencial.ler();
    if (_cred != null) _laco();
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
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({..._base(), ...corpo}))
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
    while (true) {
      try {
        final ultimo = mensagens.isEmpty ? 0 : mensagens.last.id;
        final r = await _post('sync', {'after_id': ultimo, 'wait': true}, limite: const Duration(seconds: 40));
        _aplicar(r);
      } catch (_) {
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  void _aplicar(Map<String, dynamic> r) {
    final conversa = r['conversa'] as Map<String, dynamic>?;
    final novas = ((r['mensagens'] as List?) ?? []).map((m) => ChatMensagem.json(m as Map<String, dynamic>)).toList();
    final id = conversa?['id']?.toString();
    final trocou = id != conversaId;
    if (trocou) {
      mensagens.clear();
      final eraDoCliente = _acabeiDeEnviar;
      final anterior = conversaId;
      conversaId = id;
      // P108: conversa nova que NAO foi o proprio cliente que abriu (o tecnico
      // chamou, inclusive depois de um atendimento encerrado).
      if (!_primeiraCarga && id != null && !eraDoCliente && anterior != id) {
        _tocar('nuvdesk-novo-chamado.mp3');
      }
    }
    var mensagemNovaDoTecnico = false;
    for (final m in novas) {
      if (mensagens.any((x) => x.id == m.id)) continue;
      mensagens.add(m);
      if (m.remetente == 'operator' && !trocou) mensagemNovaDoTecnico = true;
    }
    status = (conversa?['status'] ?? '').toString();
    atendente = (conversa?['atendente'] ?? '').toString();
    naoLidas = (r['nao_lidas'] as num?)?.toInt() ?? 0;

    if (trocou && id != null && novas.isEmpty) {
      // Pediu "depois do id X" de outra conversa: busca desde o inicio.
      notifyListeners();
      _post('sync', {'after_id': 0}).then(_aplicar).catchError((Object _) {});
      return;
    }
    if (mensagemNovaDoTecnico && !_primeiraCarga) _tocar('nuvdesk-mensagem.mp3');

    final ultimaNaoLida = (r['ultima_nao_lida_id'] as num?)?.toInt() ?? 0;
    if (ultimaNaoLida > _ultimaAvisada) {
      _ultimaAvisada = ultimaNaoLida;
      // O tecnico escreveu: abre o chat e traz a janela pra frente.
      abrir(trazerJanela: true);
    } else if (aberto) {
      marcarLidas();
    }
    _primeiraCarga = false;
    notifyListeners();
  }

  void _tocar(String arquivo) {
    _som.stop().then((_) => _som.play(AssetSource(arquivo))).catchError((Object _) {});
  }

  void abrir({bool trazerJanela = false}) {
    if (!aberto) {
      aberto = true;
      notifyListeners();
      aoMudarTamanho?.call();
    }
    if (trazerJanela) {
      windowManager.show();
      windowManager.focus();
    }
    marcarLidas();
  }

  void fechar() {
    if (gravandoDesde != null) pararGravacao(enviar: false);
    aberto = false;
    notifyListeners();
    aoMudarTamanho?.call();
  }

  void alternar() => aberto ? fechar() : abrir();

  void marcarLidas() {
    final ultima = mensagens.lastWhere((m) => m.remetente == 'operator', orElse: () => ChatMensagem.json({'id': 0}));
    if (naoLidas == 0 || ultima.id == 0) return;
    _post('read', {'up_to_id': ultima.id}).then((_) {
      naoLidas = 0;
      notifyListeners();
    }).catchError((Object _) {});
  }

  void _definirErro(Object e) {
    final t = e.toString().replaceFirst('Exception: ', '');
    if (e is TimeoutException || e is SocketException || t.contains('SocketException')) {
      erro = 'Sem conexão com o suporte. Verifique a internet.';
    } else if (t.startsWith('tipo de arquivo nao permitido')) {
      erro = 'Tipo de arquivo não aceito. Envie imagem, áudio, PDF, Word, Excel, TXT, XML, ZIP ou certificado.';
    } else if (t.contains('10 MB')) {
      erro = 'O arquivo passa de 10 MB.';
    } else if (t.startsWith('microfone')) {
      erro = t;
    } else {
      erro = 'Não foi possível enviar. Tente de novo.';
    }
    notifyListeners();
  }

  Future<void> _sincronizarDepoisDeEnviar(Map<String, dynamic> resposta) async {
    final conversa = resposta['conversa'] as Map<String, dynamic>?;
    if (conversa != null && conversa['id']?.toString() != conversaId) {
      _aplicar(await _post('sync', {'after_id': 0}));
    } else {
      final ultimo = mensagens.isEmpty ? 0 : mensagens.last.id;
      _aplicar(await _post('sync', {'after_id': ultimo}));
    }
  }

  Future<bool> enviarTexto(String texto) async {
    texto = texto.trim();
    if (texto.isEmpty || enviando) return false;
    enviando = true;
    // Antes do envio: o laco de espera pode receber a conversa nova ANTES da
    // resposta deste POST, e nao deve tocar "novo chamado" pro proprio cliente.
    _acabeiDeEnviar = true;
    erro = '';
    notifyListeners();
    try {
      final r = await _post('send', {'body': texto});
      await _sincronizarDepoisDeEnviar(r);
      return true;
    } catch (e) {
      _definirErro(e);
      return false;
    } finally {
      enviando = false;
      _acabeiDeEnviar = false;
      notifyListeners();
    }
  }

  Future<void> enviarAnexo(Uint8List bytes, String nome) async {
    if (enviando) return;
    if (bytes.length > _anexoMax) {
      _definirErro(Exception('arquivo maior que 10 MB'));
      return;
    }
    enviando = true;
    // Antes do envio: o laco de espera pode receber a conversa nova ANTES da
    // resposta deste POST, e nao deve tocar "novo chamado" pro proprio cliente.
    _acabeiDeEnviar = true;
    erro = '';
    notifyListeners();
    try {
      final r = await _cliente
          .post(Uri.parse('${_cred!.api}/api/v1/agent/chat/anexos'),
              headers: {
                'X-Machine-Id': _cred!.maquina,
                'X-Agent-Token': _cred!.token,
                'X-Windows-User': Uri.encodeComponent(Platform.environment['USERNAME'] ?? ''),
                'X-File-Name': Uri.encodeComponent(nome),
              },
              body: bytes)
          .timeout(const Duration(seconds: 90));
      final texto = utf8.decode(r.bodyBytes);
      final json = texto.isEmpty ? <String, dynamic>{} : jsonDecode(texto) as Map<String, dynamic>;
      if (r.statusCode >= 400) throw Exception((json['error'] ?? 'falha').toString());
      await _sincronizarDepoisDeEnviar(json);
    } catch (e) {
      _definirErro(e);
    } finally {
      enviando = false;
      _acabeiDeEnviar = false;
      notifyListeners();
    }
  }

  Future<void> enviarArquivoDoDisco(String caminho) async {
    try {
      final arquivo = File(caminho);
      if (await arquivo.length() > _anexoMax) {
        _definirErro(Exception('arquivo maior que 10 MB'));
        return;
      }
      final nome = caminho.split(RegExp(r'[\\/]')).last;
      await enviarAnexo(await arquivo.readAsBytes(), nome);
    } catch (e) {
      _definirErro(e);
    }
  }

  Future<void> escolherArquivo() async {
    final escolha = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: _extensoes);
    final caminho = escolha?.files.single.path;
    if (caminho != null) await enviarArquivoDoDisco(caminho);
  }

  /// P104: Ctrl+V. Print copiado vira imagem; arquivos copiados no Explorer vao
  /// como anexo. Devolve true se tratou (entao o texto nao e colado).
  Future<bool> colar() async {
    try {
      final arquivos = await Pasteboard.files();
      if (arquivos.isNotEmpty) {
        for (final f in arquivos.take(5)) {
          await enviarArquivoDoDisco(f);
        }
        return true;
      }
      final texto = await Clipboard.getData(Clipboard.kTextPlain);
      if (texto?.text?.isNotEmpty ?? false) return false;
      final imagem = await Pasteboard.image;
      if (imagem != null && imagem.isNotEmpty) {
        await enviarAnexo(imagem, 'print.png');
        return true;
      }
    } catch (_) {}
    return false;
  }

  // --- P106: audio ----------------------------------------------------------

  Future<void> comecarGravacao() async {
    erro = '';
    try {
      if (!await _gravador.hasPermission()) {
        _definirErro(Exception('microfone: permita o uso do microfone nas Configurações do Windows.'));
        return;
      }
      final pasta = await getTemporaryDirectory();
      final caminho = '${pasta.path}\\nuvdesk-audio-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _gravador.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100),
          path: caminho);
      gravandoDesde = DateTime.now();
      _cronometro = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (gravandoDesde != null && DateTime.now().difference(gravandoDesde!) >= _audioMax) {
          pararGravacao(enviar: true);
        } else {
          notifyListeners();
        }
      });
      notifyListeners();
    } catch (e) {
      _definirErro(Exception('microfone: nenhum microfone disponível.'));
    }
  }

  Future<void> pararGravacao({required bool enviar}) async {
    _cronometro?.cancel();
    _cronometro = null;
    gravandoDesde = null;
    notifyListeners();
    try {
      final caminho = await _gravador.stop();
      if (caminho == null) return;
      final arquivo = File(caminho);
      if (enviar && await arquivo.exists()) {
        final agora = DateTime.now();
        final nome = 'audio-${agora.year}${_2(agora.month)}${_2(agora.day)}-${_2(agora.hour)}${_2(agora.minute)}${_2(agora.second)}.m4a';
        await enviarAnexo(await arquivo.readAsBytes(), nome);
      }
      if (await arquivo.exists()) await arquivo.delete();
    } catch (e) {
      if (enviar) _definirErro(e);
    }
  }

  static String _2(int n) => n.toString().padLeft(2, '0');

  // --- anexos recebidos ----------------------------------------------------

  Future<Uint8List?> baixarAnexo(String id) {
    return _anexos.putIfAbsent(id, () async {
      try {
        final r = await _cliente.get(Uri.parse('${_cred!.api}/api/v1/agent/chat/anexos/$id'), headers: {
          'X-Machine-Id': _cred!.maquina,
          'X-Agent-Token': _cred!.token,
        }).timeout(const Duration(seconds: 60));
        if (r.statusCode == 200) return r.bodyBytes;
      } catch (_) {}
      _anexos.remove(id);
      return null;
    });
  }

  /// Salva o anexo em Downloads (nome sem sobrescrever) e devolve o caminho.
  Future<String?> salvarEmDownloads(ChatMensagem m) async {
    final bytes = await baixarAnexo(m.anexoId!);
    if (bytes == null) return null;
    final pasta = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final nome = m.anexoNome.isEmpty ? 'arquivo' : m.anexoNome;
    final ponto = nome.lastIndexOf('.');
    final base = ponto > 0 ? nome.substring(0, ponto) : nome;
    final ext = ponto > 0 ? nome.substring(ponto) : '';
    var caminho = '${pasta.path}\\$nome';
    for (var i = 1; await File(caminho).exists(); i++) {
      caminho = '${pasta.path}\\$base ($i)$ext';
    }
    await File(caminho).writeAsBytes(bytes);
    return caminho;
  }
}

// =============================================================================
// Botao da esquerda

class NuvDeskChatBotao extends StatelessWidget {
  const NuvDeskChatBotao({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    nuvdeskChat.iniciar();
    return ListenableBuilder(
      listenable: nuvdeskChat,
      builder: (context, _) {
        if (!nuvdeskChat.disponivel) return const SizedBox.shrink();
        final aberto = nuvdeskChat.aberto;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Material(
            color: aberto ? _azulClaro : _azul,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: nuvdeskChat.alternar,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                child: Row(
                  children: [
                    Icon(Icons.forum_outlined, color: aberto ? _azul : Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(aberto ? 'Fechar o chat' : 'Fale com o Suporte',
                          style: TextStyle(
                              color: aberto ? _azul : Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                    if (nuvdeskChat.naoLidas > 0 && !aberto)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: _laranja, borderRadius: BorderRadius.circular(10)),
                        child: Text('${nuvdeskChat.naoLidas}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// Painel da direita (P103)

class NuvDeskChatPainel extends StatefulWidget {
  const NuvDeskChatPainel({Key? key}) : super(key: key);

  @override
  State<NuvDeskChatPainel> createState() => _NuvDeskChatPainelState();
}

class _NuvDeskChatPainelState extends State<NuvDeskChatPainel> {
  final _texto = TextEditingController();
  final _rolagem = ScrollController();
  final _foco = FocusNode();
  int _qtdAnterior = 0;

  @override
  void initState() {
    super.initState();
    _texto.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _foco.requestFocus());
  }

  @override
  void dispose() {
    _texto.dispose();
    _rolagem.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _rolarProFim() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_rolagem.hasClients) _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
    });
  }

  Future<void> _enviarTexto() async {
    if (await nuvdeskChat.enviarTexto(_texto.text)) _texto.clear();
    _foco.requestFocus();
  }

  String _hora(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: nuvdeskChat,
      builder: (context, _) {
        final c = nuvdeskChat;
        if (c.mensagens.length != _qtdAnterior) {
          _qtdAnterior = c.mensagens.length;
          _rolarProFim();
        }
        final linhaStatus = c.conversaId == null
            ? 'Escreva sua dúvida que um técnico responde por aqui.'
            : c.status == 'closed'
                ? 'Atendimento encerrado. Escreva para abrir outro.'
                : c.atendente.isNotEmpty
                    ? 'Em atendimento com ${c.atendente}'
                    : 'Aguardando um técnico...';
        return Container(
          color: Colors.white,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 12),
                color: _azul,
                child: Row(
                  children: [
                    const Icon(Icons.support_agent, color: Colors.white, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Suporte',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 17)),
                          const SizedBox(height: 2),
                          Text(linhaStatus, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fechar o chat',
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: c.fechar,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFFF5F7FA),
                  child: c.mensagens.isEmpty
                      ? const Center(
                          child: Text('Nenhuma mensagem ainda.', style: TextStyle(color: Colors.black45, fontSize: 14)))
                      : ListView.builder(
                          controller: _rolagem,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          itemCount: c.mensagens.length,
                          itemBuilder: (_, i) => _bolha(c.mensagens[i]),
                        ),
                ),
              ),
              if (c.erro.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: const Color(0xFFFEE4E2),
                  child: Text(c.erro, style: const TextStyle(color: Color(0xFFB42318), fontSize: 13)),
                ),
              _barraDeEscrita(c),
            ],
          ),
        );
      },
    );
  }

  Widget _barraDeEscrita(NuvDeskChatControle c) {
    final gravando = c.gravandoDesde != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 10, 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFD9E0E8)))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: gravando
            ? [
                IconButton(
                  tooltip: 'Descartar áudio',
                  icon: const Icon(Icons.delete_outline, color: Color(0xFFB42318)),
                  onPressed: () => c.pararGravacao(enviar: false),
                ),
                Expanded(
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF5F5),
                      border: Border.all(color: const Color(0xFFFECDCA)),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.fiber_manual_record, color: Color(0xFFD92D20), size: 14),
                        const SizedBox(width: 8),
                        Text('Gravando ${_duracao(DateTime.now().difference(c.gravandoDesde!))}',
                            style: const TextStyle(color: Color(0xFFB42318), fontWeight: FontWeight.w600)),
                        const Spacer(),
                        const Text('máx. 5:00', style: TextStyle(color: Colors.black45, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _botaoRedondo(icone: Icons.send, dica: 'Enviar áudio', aoTocar: () => c.pararGravacao(enviar: true)),
              ]
            : [
                IconButton(
                  tooltip: 'Enviar arquivo (ou cole um print com Ctrl+V)',
                  icon: const Icon(Icons.attach_file),
                  onPressed: c.enviando ? null : c.escolherArquivo,
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, evento) {
                      if (evento is! KeyDownEvent) return KeyEventResult.ignored;
                      final ctrl = HardwareKeyboard.instance.isControlPressed;
                      // P104: Ctrl+V com imagem/arquivo na area de transferencia.
                      if (ctrl && evento.logicalKey == LogicalKeyboardKey.keyV) {
                        c.colar().then((tratado) {
                          if (!tratado) {
                            Clipboard.getData(Clipboard.kTextPlain).then((d) {
                              final t = d?.text;
                              if (t == null || t.isEmpty) return;
                              final sel = _texto.selection;
                              final inicio = sel.isValid ? sel.start : _texto.text.length;
                              final fim = sel.isValid ? sel.end : _texto.text.length;
                              _texto.value = TextEditingValue(
                                text: _texto.text.replaceRange(inicio, fim, t),
                                selection: TextSelection.collapsed(offset: inicio + t.length),
                              );
                            });
                          }
                        });
                        return KeyEventResult.handled;
                      }
                      // Enter envia; Shift+Enter quebra linha.
                      if ((evento.logicalKey == LogicalKeyboardKey.enter ||
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
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Escreva uma mensagem',
                        counterText: '',
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF5F7FA),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // P106: vazio = microfone; com texto = enviar.
                _texto.text.trim().isEmpty
                    ? _botaoRedondo(icone: Icons.mic, dica: 'Gravar áudio', aoTocar: c.enviando ? null : c.comecarGravacao)
                    : _botaoRedondo(icone: Icons.send, dica: 'Enviar', aoTocar: c.enviando ? null : _enviarTexto),
              ],
      ),
    );
  }

  Widget _botaoRedondo({required IconData icone, required String dica, VoidCallback? aoTocar}) {
    return Tooltip(
      message: dica,
      child: Material(
        color: aoTocar == null ? _azul.withOpacity(0.5) : _azul,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: aoTocar,
          child: SizedBox(width: 44, height: 44, child: Icon(icone, color: Colors.white, size: 22)),
        ),
      ),
    );
  }

  static String _duracao(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _bolha(ChatMensagem m) {
    if (m.remetente == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFE9EDF2), borderRadius: BorderRadius.circular(12)),
            child: Text('${m.texto} · ${_hora(m.criada)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
        ),
      );
    }
    final meu = m.remetente == 'client';
    return Align(
      alignment: meu ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: meu ? _azulClaro : Colors.white,
          border: Border.all(color: const Color(0xFFD9E0E8)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!meu && m.autor.isNotEmpty)
              Text(m.autor, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _azul)),
            if (m.anexoId != null) _anexo(m),
            if (m.texto.isNotEmpty) SelectableText(m.texto, style: const TextStyle(fontSize: 15, height: 1.35)),
            Align(
              alignment: Alignment.centerRight,
              child: Text(_hora(m.criada), style: const TextStyle(fontSize: 11, color: Colors.black45)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _anexo(ChatMensagem m) {
    switch (m.anexoTipo) {
      case 'audio':
        return _BolhaAudio(mensagem: m);
      case 'arquivo':
        return _BolhaArquivo(mensagem: m);
      default:
        return FutureBuilder<Uint8List?>(
          future: nuvdeskChat.baixarAnexo(m.anexoId!),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(width: 160, height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
            }
            final bytes = snap.data;
            if (bytes == null) {
              return const Text('Imagem indisponível',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.black45));
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
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(bytes, height: 200, fit: BoxFit.contain),
              ),
            );
          },
        );
    }
  }
}

String _tamanhoLegivel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

class _BolhaArquivo extends StatefulWidget {
  final ChatMensagem mensagem;
  const _BolhaArquivo({required this.mensagem});

  @override
  State<_BolhaArquivo> createState() => _BolhaArquivoState();
}

class _BolhaArquivoState extends State<_BolhaArquivo> {
  String? _salvoEm;
  bool _baixando = false;
  bool _falhou = false;

  Future<void> _baixar() async {
    if (_salvoEm != null) {
      // Abre a PASTA, nao o arquivo: nada que o tecnico mande roda sozinho.
      await launchUrl(Uri.file(File(_salvoEm!).parent.path));
      return;
    }
    setState(() => _baixando = true);
    final caminho = await nuvdeskChat.salvarEmDownloads(widget.mensagem);
    if (!mounted) return;
    setState(() {
      _baixando = false;
      _salvoEm = caminho;
      _falhou = caminho == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mensagem;
    final legenda = _falhou
        ? 'Não foi possível baixar'
        : _salvoEm != null
            ? 'Salvo em Downloads · clique para abrir a pasta'
            : '${_tamanhoLegivel(m.anexoTamanho)} · clique para baixar';
    return InkWell(
      onTap: _baixando ? null : _baixar,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 300,
        margin: const EdgeInsets.only(top: 2, bottom: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          border: Border.all(color: const Color(0xFFD9E0E8)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            _baixando
                ? const SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.insert_drive_file_outlined, color: _azul, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.anexoNome.isEmpty ? 'arquivo' : m.anexoNome,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(legenda, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BolhaAudio extends StatefulWidget {
  final ChatMensagem mensagem;
  const _BolhaAudio({required this.mensagem});

  @override
  State<_BolhaAudio> createState() => _BolhaAudioState();
}

class _BolhaAudioState extends State<_BolhaAudio> {
  final _player = AudioPlayer();
  final List<StreamSubscription> _escutas = [];
  String? _arquivo;
  bool _tocando = false;
  bool _carregando = false;
  bool _falhou = false;
  Duration _posicao = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _escutas.add(_player.onPositionChanged.listen((p) => mounted ? setState(() => _posicao = p) : null));
    _escutas.add(_player.onDurationChanged.listen((d) => mounted ? setState(() => _total = d) : null));
    _escutas.add(_player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _tocando = false;
          _posicao = Duration.zero;
        });
      }
    }));
  }

  @override
  void dispose() {
    for (final e in _escutas) {
      e.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _alternar() async {
    if (_tocando) {
      await _player.pause();
      setState(() => _tocando = false);
      return;
    }
    try {
      if (_arquivo == null) {
        setState(() => _carregando = true);
        final bytes = await nuvdeskChat.baixarAnexo(widget.mensagem.anexoId!);
        if (bytes == null) throw Exception('sem audio');
        final pasta = await getTemporaryDirectory();
        final nome = widget.mensagem.anexoNome.isEmpty ? 'audio.m4a' : widget.mensagem.anexoNome;
        final caminho = '${pasta.path}\\nuvdesk-${widget.mensagem.anexoId}-$nome';
        await File(caminho).writeAsBytes(bytes);
        _arquivo = caminho;
        await _player.setSource(DeviceFileSource(caminho));
      }
      await _player.resume();
      if (mounted) {
        setState(() {
          _carregando = false;
          _tocando = true;
          _falhou = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _carregando = false;
          _falhou = true;
        });
      }
    }
  }

  static String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_falhou && _arquivo != null) {
      // Formato que o Windows nao toca sozinho (ex.: WebM): abre no player padrao.
      return TextButton.icon(
        onPressed: () => launchUrl(Uri.file(_arquivo!)),
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Abrir áudio no computador'),
      );
    }
    final progresso = _total.inMilliseconds > 0 ? _posicao.inMilliseconds / _total.inMilliseconds : 0.0;
    return SizedBox(
      width: 280,
      child: Row(
        children: [
          IconButton(
            onPressed: _carregando ? null : _alternar,
            icon: _carregando
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_tocando ? Icons.pause_circle_filled : Icons.play_circle_fill, color: _azul, size: 36),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: progresso.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: const Color(0xFFD9E0E8),
                  color: _azul,
                ),
                const SizedBox(height: 4),
                Text(_falhou ? 'Não foi possível tocar' : '${_fmt(_posicao)} / ${_fmt(_total)}',
                    style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
