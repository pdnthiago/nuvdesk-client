import 'dart:convert';
import 'dart:io';

/// Versao do NuvDesk (a NOSSA, semantica MAJOR.MINOR.PATCH), gravada pelo
/// instalador em `%ProgramData%\NuvDesk\state.json`.
///
/// Por que nao usar a versao do proprio RustDesk: ela e uma constante do fonte
/// (1.5.0), igual em toda build nossa, entao nao diz qual geracao do NuvDesk a
/// maquina tem. E ela NAO pode ser renumerada pra virar a nossa: os dois lados
/// da sessao comparam esse numero pra decidir o que liberar (area de
/// transferencia >= 1.3.0, copiar e colar arquivo >= 1.3.8, modos de teclado).
/// Baixar ela desligaria esses recursos em silencio. As duas convivem: a do
/// RustDesk segue funcionando por dentro, invisivel; a nossa e a que aparece.
///
/// Lido uma vez e guardado: o instalador so escreve esse arquivo na instalacao,
/// e isto e chamado de dentro de um `build()`.
String? _cache;
bool _lido = false;

/// Versao do NuvDesk Rapido. O Rapido nao passa pelo instalador, entao nao
/// tem state.json proprio - e numa maquina que tambem tem o agente, ler o
/// state.json mostrava a versao do INSTALADO. Subir a cada build do Rapido
/// (regra de versionamento do CLAUDE.md do NuvDesk).
const String kNuvdeskRapidoVersao = '1.0.4';

String? nuvdeskVersao() {
  if (_lido) return _cache;
  _lido = true;
  // O empacotador do Rapido (libs/portable) exporta RUSTDESK_APPNAME.
  if (Platform.environment.containsKey('RUSTDESK_APPNAME')) {
    _cache = kNuvdeskRapidoVersao;
    return _cache;
  }
  try {
    final base = Platform.environment['ProgramData'];
    if (base == null) return null;
    final arquivo = File('$base\\NuvDesk\\state.json');
    if (!arquivo.existsSync()) return null;
    var texto = arquivo.readAsStringSync();
    // O PowerShell grava com BOM as vezes.
    if (texto.isNotEmpty && texto.codeUnitAt(0) == 0xFEFF) {
      texto = texto.substring(1);
    }
    final v = jsonDecode(texto) as Map<String, dynamic>;
    final versao = (v['nuvdesk_version'] ?? '').toString().trim();
    _cache = versao.isEmpty ? null : versao;
  } catch (_) {
    // Sem versao a tela so nao mostra a linha - nada mais depende disto.
  }
  return _cache;
}
