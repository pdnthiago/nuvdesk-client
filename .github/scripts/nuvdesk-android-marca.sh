#!/usr/bin/env bash
# Marca NuvDesk no app Android: nome, servidor, chave, identificador, rodape e
# icones. Usado pelos dois jobs Android da CI (APK por arquitetura e AAB da Play
# Store) - antes era um passo copiado em cada job, e o universal saia sem marca.
#
# Roda na raiz do repositorio, depois do checkout.
set -euo pipefail
set -x

CFG=libs/hbb_common/src/config.rs
sed -i 's#RwLock::new("RustDesk".to_owned())#RwLock::new("NuvDesk".to_owned())#' "$CFG"
sed -i 's#pub const RENDEZVOUS_SERVERS: &\[&str\] = &\["rs-ny.rustdesk.com"\];#pub const RENDEZVOUS_SERVERS: \&[\&str] = \&["rd.nuvdeskapp.com.br"];#' "$CFG"
sed -i 's#pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";#pub const RS_PUB_KEY: \&str = "HSESrNvGi58goHMZL1ucRLrehTI8FdukeCYFOQJIydo=";#' "$CFG"
grep -nE 'APP_NAME: RwLock|RENDEZVOUS_SERVERS:|RS_PUB_KEY:' "$CFG"

# Nome que aparece embaixo do icone e no servico de acessibilidade.
M=flutter/android/app/src/main/AndroidManifest.xml
sed -i 's#android:label="RustDesk Input"#android:label="NuvDesk Input"#; s#android:label="RustDesk"#android:label="NuvDesk"#' "$M"
grep -n 'android:label' "$M"

# Identificador proprio do app: sem ele o NuvDesk brigaria com o RustDesk no
# mesmo aparelho (um substituiria o outro) e a Play Store recusaria, porque
# com.carriez.flutter_hbb ja e do RustDesk.
sed -i 's#applicationId "com.carriez.flutter_hbb"#applicationId "br.com.nuvsoft.nuvdesk"#' flutter/android/app/build.gradle
grep -n 'applicationId' flutter/android/app/build.gradle

# "Desenvolvido por RustDesk" -> Nuvsoft, e o link do rodape.
COMMON=flutter/lib/common.dart
sed -i "s#launchUrl(Uri.parse('https://rustdesk.com'));#launchUrl(Uri.parse('https://www.nuvsoft.com.br'));#" "$COMMON"
sed -i 's#translate("powered_by_me")#"Desenvolvido por Nuvsoft"#' "$COMMON"
grep -n 'nuvsoft.com.br\|Desenvolvido por Nuvsoft' "$COMMON"

# Textos exibidos: "RustDesk" -> "NuvDesk" so no VALOR de cada traducao. A
# chave nao pode mudar: varias contem "RustDesk" (ex.: "Keep RustDesk background
# service") e o app procura o texto por ela. So no build Android, pra nao mexer
# no agente Windows (que teria de subir de versao).
python3 - <<'PY'
import glob, re
par = re.compile(r'^(\s*\("(?:[^"\\]|\\.)*",\s*")((?:[^"\\]|\\.)*)("\),?\s*)$')
total = 0
for arq in glob.glob("src/lang/*.rs"):
    linhas = open(arq, encoding="utf-8").read().split("\n")
    for n, l in enumerate(linhas):
        m = par.match(l)
        if m and "RustDesk" in m.group(2):
            linhas[n] = m.group(1) + m.group(2).replace("RustDesk", "NuvDesk") + m.group(3)
            total += 1
    open(arq, "w", encoding="utf-8").write("\n".join(linhas))
print("traducoes com RustDesk -> NuvDesk:", total)
PY
grep -n 'android_input_permission_tip1' src/lang/ptbr.rs

# Icones a partir de nuvdesk-icon.png (raiz do repo).
sudo apt-get install -y imagemagick >/dev/null
RES=flutter/android/app/src/main/res
# Icone classico (Android 7 e anteriores) e o redondo.
for par in "mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192"; do
  set -- $par
  convert nuvdesk-icon.png -resize ${2}x${2} "$RES/mipmap-$1/ic_launcher.png"
  convert nuvdesk-icon.png -resize ${2}x${2} "$RES/mipmap-$1/ic_launcher_round.png"
done
# Icone adaptativo (Android 8+): o sistema recorta a imagem, entao a arte ocupa
# so o miolo (66%) de uma tela transparente maior.
for par in "mdpi 108 72" "hdpi 162 108" "xhdpi 216 144" "xxhdpi 324 216" "xxxhdpi 432 288"; do
  set -- $par
  convert nuvdesk-icon.png -resize ${3}x${3} -background none -gravity center -extent ${2}x${2} \
    "$RES/mipmap-$1/ic_launcher_foreground.png"
done
# Icone monocromatico da barra de notificacao.
for par in "mdpi 24" "hdpi 36" "xhdpi 48" "xxhdpi 72" "xxxhdpi 96"; do
  set -- $par
  convert nuvdesk-icon.png -resize ${2}x${2} -alpha extract -threshold 0 \
    "$RES/mipmap-$1/ic_stat_logo.png" 2>/dev/null || true
done
ls -l "$RES/mipmap-xxxhdpi"
