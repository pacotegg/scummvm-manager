# ScummVM Collection Manager

Herramienta de consola (PowerShell) para gestionar una colección de juegos
ScummVM pensada para un frontend estilo EmulationStation / RetroBat / RetroDeck.

Creado por **PaCo_El_FLaCo**.

---

## Qué hace

- **Scan**: detecta los juegos con `scummvm.exe --detect`, extrae metadata
  (título, serie, edición, plataforma, idioma), quita duplicados **quedándose
  con la mejor versión** (según idioma/plataforma preferidos, CD/Talkie/
  Restored) y guarda la base de datos en `Database\games.json`. Al terminar
  muestra el **Import Status** (ver abajo).
- **Browse**: navega la colección por Título / Serie / Engine / Idioma /
  Plataforma, con buscador incremental, color por estado de media y badge de
  engine.
- **Validate**: compara la colección contra el catálogo canónico
  (`Definitions\games.json`).
- **Sync Frontend**: mantiene "viva" la carpeta del frontend —
  - *Detect NEW*: crea el `.scummvm` y la entrada en `gamelist.xml` de los
    juegos nuevos (con detección de respaldo por nombre vía `KnownGames.json`
    cuando `--detect` no reconoce).
  - *Fix EXISTING naming*: renombra carpetas mal nombradas a la convención
    (guiones bajos) y actualiza `gamelist.xml` + media **sin perder** el
    trabajo scrapeado.
  - *Dry-run*: enseña el plan sin tocar nada.
  - *Undo*: revierte el último Sync.
- **Import Status**: tras cada Scan (y bajo demanda en Tools) clasifica **cada
  carpeta** de la colección y comprueba si tiene su fichero `.scummvm`:
  - *Detectada + `.scummvm`* → OK, aparece en el frontend.
  - *Detectada sin `.scummvm`* → falta un Sync Frontend.
  - *Sin detectar pero con `.scummvm`* → RetroBat la lanza igual.
  - *Sin detectar y sin `.scummvm`* → no aparecerá; si tiene un ID en
    `KnownGames.json` te lo indica (basta un Sync), y si no, es un juego
    no-ScummVM (candidato al Windows Linker).
- **Edition Advisor**: detecta la edición (Floppy/CD/Talkie…) y avisa si existe
  una mejor, con enlaces a ScummVM/GOG.
- **Tools & Maintenance**: Doctor (salud: duplicados, huérfanos, media
  faltante), Export CSV/HTML, limpiar huérfanos, restaurar backup, Bundle
  Assistant, Media Finder, auto-descarga de portadas/marquees (SteamGridDB),
  generar miniaturas, **Import Status** y **Windows Linker**.
- **Windows Linker**: para los juegos que **no** son de ScummVM (nativos, Unity,
  Visionaire…) crea un acceso directo `.lnk` en la carpeta `roms\windows` de
  RetroBat apuntando a su `.exe` — **sin mover los datos** — y añade su entrada
  al `gamelist.xml` de esa carpeta. Detecta el `.exe` principal automáticamente
  (filtrando instaladores/crash-handlers) y te deja confirmarlo, elegir otro o
  dar una ruta a mano.
- **Settings**: Unicode/ASCII, acento de color, preferencias de dedup, rutas.

---

## Instalación / primer uso

1. Copia la carpeta del proyecto a donde quieras (es **portable**: las rutas
   internas se resuelven solas respecto a su ubicación).
2. Coloca el binario portable de ScummVM en `Bin\ScummVM\scummvm.exe`.
3. Permite ejecutar scripts locales (una sola vez, como tu usuario):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   Get-ChildItem -Recurse | Unblock-File
   ```
4. Lanza:
   ```powershell
   .\Manage-ScummVM.ps1
   ```
   Si falta alguna ruta, el asistente de primer arranque te la pide.

---

## Dos interfaces: consola (TUI) y ventanas (GUI)

El mismo motor (los módulos `.psm1`) se usa desde dos frontends:

- **Consola (TUI)** — `Manage-ScummVM.ps1` o `ScummVM Manager (consola).cmd`.
  Menús navegables con flechas, colores y cajas.
- **Ventanas (GUI, WPF)** — `ScummVM-Manager-GUI.ps1` o
  `ScummVM Manager (GUI).cmd`. Rediseño estilo aventura gráfica:
  - **Galería** de carátulas (o vista **Lista**) con franja de color por estado
    de media, chip de engine y buscador incremental. Placeholder con degradado
    cuando aún no hay carátula.
  - Panel de detalle con **portada grande**, metadatos (ScummVM ID, engine,
    serie, edición…), checklist de media y **barra de verbos** (Ver carátula,
    Abrir carpeta, Editar ficha, Media Finder, Bajar carátula, Descargar media,
    **Buscar imagen**, **Bajar video 15s**, **Buscar manual**).
  - **Buscar imagen** (por juego): busca en **DuckDuckGo Images** (sin key, el
    sustituto de Google) por texto libre para portada/fanart/snap/marquee,
    muestra una **rejilla de miniaturas**; al hacer clic descarga la elegida,
    la coloca en la carpeta correcta y actualiza `gamelist.xml`. Incluye
    "pegar URL" como respaldo.
  - **Bajar video 15s** (por juego): con **yt-dlp + ffmpeg** (en el PATH) coge
    un tramo de **gameplay** (salta la intro), lo recorta a ≤30 s y lo comprime
    fuerte (480p, H.264 CRF 30 → pocas decenas de KB) manteniendo calidad
    decente; lo coloca en `videos/` y actualiza `gamelist.xml`. Acepta búsqueda
    o URL de YouTube.
  - **Buscar manual** (por juego): busca en **archive.org** (ordenado por
    relevancia), lista los que tienen **PDF**, y al elegir uno lo descarga a
    `manuals/` y actualiza `gamelist.xml`. Incluye "pegar URL de PDF".
  - **Descargar media** masivo: además de las APIs, cae de vuelta a
    **DuckDuckGo** al final para rellenar lo que ninguna fuente encuentra.
  - **Tema Noche/Día** conmutable en caliente y **acento configurable**
    (Gold / Cyan / Green / Magenta / Blue) desde Ajustes.
  - **Watch-folder**: detecta carpetas nuevas en la carpeta de ROMs y avisa con
    una banda para revisar y sincronizar.
  - **Descargar media** multi-fuente con **fallback**: portada, snap, vídeo,
    marquee, fanart y manual. Si una fuente no lo tiene, prueba la siguiente
    (SteamGridDB → ScreenScraper → TheGamesDB → libretro). Cola con progreso.
  - **Editor de ficha** (`gamelist.xml`): nombre, descripción y rating.
  - **Rescan**, **Sync Frontend** (plan en tabla + aplicar Nuevos/Renombres/Todo
    con confirmación y backup), **Doctor** y **Ajustes**.
  - Las tareas lentas (scan, descargas) corren en segundo plano: la ventana
    no se congela.

### Compilar a `.exe` (opcional)

Para tener un ejecutable con icono que se lanza con doble clic:

```powershell
.\Build-Exe.ps1          # instala ps2exe si falta y genera "ScummVM Manager.exe"
```

El `.exe` **debe quedarse en esta carpeta** (carga `Modules\` y `config.json`
desde su propia ubicación en runtime; no los empaqueta dentro). Si copias el
proyecto a otro PC, copia la carpeta entera y el `.exe` seguirá funcionando.
El icono se genera con `Tools\Generate-Icon.ps1`.

---

## Configuración (`config.json`)

- `Paths.ScummVM` — ruta al ejecutable (relativa = dentro del proyecto).
- `Paths.RomFolder` — carpeta de tus juegos ScummVM (con `images/`, `videos/`,
  `manuals/`, `marquees/`, `snaps/` y `gamelist.xml`).
- `Paths.WindowsRomFolder` — carpeta del sistema `windows` de RetroBat para el
  **Windows Linker**. Déjala vacía (`""`) para usar la carpeta hermana
  `windows` de tu `RomFolder` (ej. `…\roms\windows`), o pon una ruta absoluta.
- `Preferences` — idiomas/plataformas preferidos, PreferCD/Talkie/Restored,
  IgnoreDemo/Unknown, `MaxFolderNameLength`.
- `Preferences.ApiKeys.SteamGridDB` — API key gratuita para auto-descargar
  portadas (regístrate en https://www.steamgriddb.com).
- `Preferences.UI` — `Unicode` (cajas bonitas vs ASCII) y `Accent` (color).

Las rutas también se editan desde **Settings → Edit paths**.

---

## Flujo recomendado

1. **Scan** para poblar/actualizar `games.json`. Al final lee el **Import
   Status**: te dice qué carpetas quedaron fuera y por qué.
2. **Sync Frontend → Dry-run** para revisar; luego *Detect NEW* / *Fix naming*.
   *Detect NEW* también recupera juegos que `--detect` marca como "unknown
   variant" (traducciones/repacks) si están en `KnownGames.json`.
3. **Tools → Windows Linker** para los juegos no-ScummVM (nativos/Unity…):
   crea sus `.lnk` en `roms\windows` sin mover datos.
4. **Tools → Doctor** para ver huecos (media faltante, huérfanos, duplicados).
5. **Media Finder** / **Auto-descargar portadas** para rellenar media.
6. Tras renombrar, vuelve a **Scan** (los nombres de carpeta cambian).

---

## Notas

- El fichero `.scummvm` contiene el ScummVM ID (`engine:target`, ej. `sky:sky`).
  Lo que hace que RetroBat lance un juego ScummVM es la **presencia de ese
  fichero** en la carpeta; por eso el Import Status lo comprueba una a una.
- **Juegos no-ScummVM**: los motores nativos (Unity/PowerQuest como *Loco
  Motive* o *The Drifter*, Visionaire como *Foolish Mortals*, o juegos modernos
  como *Broken Sword 5*) **no** se pueden emular con ScummVM. Para esos usa el
  **Windows Linker**: se quedan instalados donde están y solo se crea un `.lnk`
  en `roms\windows`. Los que sí son ScummVM pero fallan como "unknown variant"
  (traducciones fan de *Broken Sword 1*, *Woodruff*, *Zak*…) se recuperan con
  *Sync Frontend → Detect NEW* gracias a `KnownGames.json`.
- Los datos (`games.json`, `Definitions\`, `Logs\`) y el binario (`Bin\`) son
  locales de cada máquina: al copiar el proyecto, conserva tu `Bin\ScummVM`.
- Google no se automatiza (sin API libre); el Media Finder abre la búsqueda y
  tú eliges.
- **Scrapers de media** (Ajustes): `SteamGridDB` (key gratis; carátula/fanart/
  marquee), `ScreenScraper.fr` (cuenta gratuita + Dev ID/Password de su foro;
  la única con **vídeo, snap y manual**), `MobyGames` (key gratuita en
  mobygames.com/info/api; **la mejor cobertura de aventuras clásicas** —
  carátula/snap; límite 1 petición/seg), `IGDB` (Client ID + Secret gratis de
  dev.twitch.tv; carátula/screenshot/artwork, sin Cloudflare), `TheGamesDB` (key
  pública; fallback de artwork/snap) y `libretro-thumbnails` (sin credenciales,
  siempre activo; carátula/snap) y `DuckDuckGo` (sin key, **último recurso**;
  imagen web arbitraria para rellenar huecos). Para **manuales** usa
  `archive.org` (PDF). El scraper prueba las fuentes en orden
  (`SteamGridDB → ScreenScraper → archive.org(manual) → IGDB → MobyGames →
  TheGamesDB → libretro → DuckDuckGo`) y usa la primera que encuentre la media.
  El "Descargar media" masivo también **actualiza el `gamelist.xml`** de cada
  fichero que baja (solo el campo que corresponde).
- **GiantBomb**: se probó pero **no es usable** — su API está detrás de
  Cloudflare y devuelve 403 a cualquier cliente HTTP que no sea un navegador
  real. El resolver y el campo de key quedan en el código marcados como
  bloqueados, pero fuera del orden de scraping.
- **Nota sobre ScreenScraper**: su API necesita **Dev ID/Password** (credenciales
  de software, se piden en su foro) **además** de tu usuario/contraseña. RetroBat
  funciona solo con tu cuenta porque lleva su propio Dev ID incrustado; esta app
  no está registrada, así que sin el Dev ID/Password ScreenScraper queda inactivo.

## Estructura

```
Manage-ScummVM.ps1      Punto de entrada (menú TUI)
ScummVM-Manager-GUI.ps1 Interfaz de ventanas (WPF)
config.json             Configuración (incl. WindowsRomFolder)
Definitions\            KnownGames.json, EditionUpgrades.json, games.json
Database\               SeriesRules.json, games.json (generado)
Bin\ScummVM\            scummvm.exe (lo pones tú)
Logs\                   logs, exports, backups
Modules\
  Core\                 Config, Logger, LibraryCleaner (dedup), NameSanitizer
  Library\              Scanner, Parser, Metadata, Fallback, ImportStatus,
                        MediaFinder/Status, Scrapers, Exporter, EditionAdvisor
  Database\             Database (carga/guarda games.json)
  Frontend\             GamelistXml, FrontendSync, BundleAssistant, WindowsLinker
  Repair\               Doctor, Validator
  UI\                   Theme, Selector, Browser
```

> **Nota:** *Import Status* y *Windows Linker* están disponibles en **ambas**
> interfaces: en la TUI (`Manage-ScummVM.ps1`, dentro de *Tools & Maintenance*)
> y en la GUI (botones **Estado** y **Windows** de la barra superior).
