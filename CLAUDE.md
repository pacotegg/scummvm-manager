# ScummVM Collection Manager — contexto de proyecto

Herramienta en **PowerShell** de **PaCo_El_FLaCo** para gestionar una colección de
juegos ScummVM y mantener "viva" la carpeta de un frontend **RetroBat**
(`C:\BOBwin\roms\scummvm`). Idioma del usuario: **español**. El usuario usa
principalmente la **GUI**.

Origen: el proyecto se reconstruyó a partir de un chat de ChatGPT de 568 turnos
(catalogación básica) y desde entonces se ha ampliado mucho (sync de frontend,
scrapers, buscador de media, etc.). Historial completo en
`Conversacion_completa_ScummVM-Manager.md` (referencia, no cargar entero).

## Runtime y arranque (IMPORTANTE)

- **Usa Windows PowerShell 5.1** (`powershell.exe`), NO pwsh 7. La GUI es WPF y
  en pwsh 7 falla por desajuste de ensamblados (.NET 10 vs 4). Para probar cosas
  desde el shell (que aquí es pwsh 7), invoca `powershell.exe -STA -NoProfile ...`.
- **Dos frontends que comparten los mismos módulos `.psm1`**:
  - **TUI**: `Manage-ScummVM.ps1` (consola, menús con flechas).
  - **GUI**: `ScummVM-Manager-GUI.ps1` (WPF, ~1500 líneas). Es la que usa el
    usuario. Tiene un switch `-NoShow` para arrancarla sin abrir ventana (tests).
- Lanzadores: `ScummVM Manager (consola).cmd`, `ScummVM Manager (GUI).cmd`, y el
  **`.exe`** compilado con `Build-Exe.ps1` (ps2exe).
- **El `.exe` incrusta el script de entrada** pero carga `Modules\` y
  `config.json` desde disco en runtime. **Tras tocar la GUI o los módulos hay que
  recompilar** (`Build-Exe.ps1`) para que el `.exe` lo refleje; el `.cmd` siempre
  usa el `.ps1` en vivo (no necesita recompilar). Recompilar requiere cerrar el
  `.exe` si está abierto (si no, "Acceso denegado").
- La GUI corre trabajos pesados en un **runspace de fondo** que hace dot-source de
  `$script:ImportBlockText` (la lista de `Import-Module`). Cualquier módulo nuevo
  que use un job de fondo debe estar en ese bloque.

## Arquitectura de módulos (`Modules\`)

- **Core**: `Config` (get/set config.json; `Set-SCMConfig` solo escribe
  Preferences/Application, preserva Paths del disco), `Logger`, `LibraryCleaner`
  (dedup), `NameSanitizer` (Título→`Guiones_Bajos` ASCII; detecta "nombre roto").
- **Library**: `Scanner`, `Parser`, `Metadata`, `CollectionStats`, `Fallback`
  (KnownGames.json por nombre), `ImportStatus`, `MediaStatus`, `MediaFinder`,
  `Scrapers` (multi-fuente), `MediaGrab` (buscar/colocar media a mano), `Exporter`,
  `EditionAdvisor`.
- **Database**: `Database` (carga/guarda `Database\games.json`).
- **Frontend**: `GamelistXml`, `FrontendSync`, `BundleAssistant`, `WindowsLinker`.
- **Repair**: `Doctor`, `RepairEngine`, `Validator`.
- **UI**: `Theme`, `Selector`, `Browser`.

Todas las funciones llevan prefijo `SCM`. Convención de handlers WPF y diálogos:
XAML con tokens `@INK@`/`@TEXT@`/`@ACCENT@`/etc. sustituidos por `ConvertFrom-SCMXaml`;
diálogos vía `New-SCMDialog`; `.Add_Click({ ... }.GetNewClosure())`.

## Pipeline de Scan

`Scanner` (scummvm.exe --detect --recursive) → `Parser` (GameID/Engine/Description)
→ `LibraryCleaner` (agrupa por ShortID, **se queda con la mejor versión** por
score: idioma/plataforma preferidos, CD/Talkie/Restored) → `Metadata` (serie/
edición vía `SeriesRules.json`) → guarda `Database\games.json` → **Import Status**
(clasifica cada carpeta y comprueba su `.scummvm`).

## Convenciones de la carpeta de ROMs (`C:\BOBwin\roms\scummvm`)

- **Un único `gamelist.xml` en la raíz.** Carpetas de media hermanas: `images/`,
  `videos/`, `manuals/`, `marquees/`, `snaps/`.
- Nombres de fichero de media: `<Carpeta>-image.png`, `-thumb.png`, `-fanart.jpg`,
  `-video.mp4`, `-marquee.png`, `-snap.*`, `-manual.pdf`.
- Campos de `gamelist.xml` por tipo: `image`, `thumbnail`, `fanart`, `video`,
  `marquee`, `manual`, `map`. **`snap` NO tiene campo de gamelist** (solo fichero).
- La app detecta marquee en `marquees/` y snap en `snaps/` (`MediaStatus`). El
  scraper propio de RetroBat metía el marquee en `images/-marquee`; ambos valen
  porque el gamelist apunta a donde está el fichero. Al actualizar, apuntamos al
  sitio donde la app deja el fichero (marquees/).
- `.scummvm` contiene el ScummVM ID (`engine:target`, ej. `sky:sky`). Es lo que
  hace que RetroBat lance el juego.
- Ruta de carpeta = `<path>./Carpeta/Carpeta.scummvm`. Las entradas se localizan
  por ese patrón (`Find-SCMGamelistEntryByFolder`).
- **Actualizaciones de gamelist quirúrgicas**: buscar la entrada por carpeta y
  tocar SOLO el campo que corresponde, preservando el resto (desc, id, scrap…).

## Scrapers de media

Orden de fallback (en `Invoke-SCMScrapeMedia`, solo GUI):
`SteamGridDB → ScreenScraper → archive.org(manual) → IGDB → MobyGames → TheGamesDB
→ libretro → DuckDuckGo`. Credenciales en `config.json` (`Preferences.ApiKeys` /
`Preferences.Scrapers`), editables en Ajustes.

- **IGDB**: OAuth de Twitch (ClientId+Secret, tipo *Confidential*). Activa y
  probada. Portada/screenshot/artwork.
- **SteamGridDB, TheGamesDB, libretro**: activas.
- **MobyGames** (key), **ScreenScraper** (necesita Dev ID/Password además de
  user/pass — RetroBat lleva su propio Dev ID, esta app no): a falta de creds.
- **archive.org**: manuales en PDF (con gate de relevancia por score).
- **DuckDuckGo Images**: sin key, último recurso; también alimenta el buscador
  manual "Buscar imagen".
- **GiantBomb**: NO usable — API tras Cloudflare (403). Ver `memory/`.
- El "Descargar media" masivo ahora **actualiza el gamelist** por cada fichero.

## Buscar media a mano (`MediaGrab.psm1`, verbos de la GUI)

- **Buscar imagen**: rejilla de DuckDuckGo (portada/fanart/snap/marquee), clic →
  descarga + coloca + gamelist. Con "pegar URL".
- **Bajar video 15s**: yt-dlp + ffmpeg (ambos en PATH). Coge un tramo de
  **gameplay** (salta la intro ~30% del vídeo), recorta ≤30s y comprime a 480p
  H.264 CRF 30 (pocas decenas de KB). Corre en job de fondo.
- **Buscar manual**: archive.org, lista los que tienen PDF, clic → descarga a
  `manuals/` + gamelist. Con "pegar URL de PDF".
- **Windows Linker**: juegos NO-ScummVM (Unity/nativos) → `.lnk` en `roms\windows`
  sin mover datos.

## Gotchas de PowerShell/WPF aprendidos aquí

- `"$var:"` dentro de string = referencia de ámbito → usar `"${var}"`.
- Parámetro llamado `$Args` colisiona con la variable automática `$args` (rompe el
  splatting). Usar otro nombre (`$ArgList`).
- Procesos externos (yt-dlp) escriben progreso a **stderr**; con `EAP=Stop` del
  llamante eso lanza excepción terminante → envolver la llamada con `EAP=Continue`.
- `ConvertTo-Json` de un array en PS 5.1 mete un wrapper `{value,Count}`; guardar
  con `-InputObject` y `-Depth`.
- yt-dlp: `--download-sections "*S-E"` recorta con ffmpeg; NO combinar con
  `--recode-video` (rompe el nombre de salida).

## Verificación (patrón usado)

1. Sintaxis: `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
2. GUI: `powershell.exe -STA ... -File GUI.ps1 -NoShow` + comprobar funciones/verbos.
3. XAML de diálogos: `ConvertFrom-SCMXaml` sobre el string (solo parsea al abrirse).
4. Scrapers/backends: probar en vivo aislados (temp RomFolder + gamelist) antes de
   cablear en la GUI. Confirmar HTTP 200 de las URLs.

## Flujo de trabajo con el usuario

- Antes de dar por buena media/scraper, **probar en vivo** (el usuario ya se
  quemó con fuentes que no funcionaban). Verificar de verdad, no de memoria.
- Recompilar el `.exe` al terminar cambios de GUI/módulos.
