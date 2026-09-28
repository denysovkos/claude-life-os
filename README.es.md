# claude-life-os

[English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Polski](README.pl.md) · [Français](README.fr.md) · **Español** · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Русский](README.ru.md) · [Português](README.pt.md)

Un sistema personal para el papeleo. Lee tu Gmail y tu Google Drive, mantiene un índice
de cada documento formal, carta, contrato y factura en una base de datos que es tuya, y se
asegura de que no se te pase ningún plazo, renovación ni vencimiento. Le preguntas en
lenguaje normal, en cualquier chat de Claude: «cuándo caduca mi pasaporte», «¿todavía
puedo darme de baja del gimnasio?», «qué dice el contrato de alquiler sobre mascotas».

Lo construyó una persona para su propia vida, usándolo a diario durante un mes, y ahora
se está convirtiendo en algo que cualquiera puede instalar. No hace falta programar:
Claude te guía en cada paso.

## Instalación

Esto es para Claude normal: claude.ai en el navegador, o la app de Claude en el
ordenador o el móvil.

**1. Descarga el skill: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (no lo descomprimas). Es un solo skill
que lo contiene todo: instalación, correo, archivos, comprobación nocturna, revisión
mensual y respuestas a tus preguntas. El enlace siempre apunta a la versión más reciente
([todas las versiones](https://github.com/denysovkos/claude-life-os/releases)).

**2. Añádelo a Claude.** En Claude abre **Settings** → **Capabilities**, activa
**Code execution and file creation** (los skills lo necesitan) y luego, en **Skills**,
pulsa **Upload skill** y elige `life-os.zip`.

**3. Conecta tus cuentas.** **Settings** → **Connectors**: Google Drive, Gmail y
Supabase; si quieres también Google Calendar, Todoist, Craft.

**4. Abre un chat nuevo y escribe: `set up life os`.** A partir de aquí guía Claude. Hace
unas preguntas (tu idioma, tu país, qué apps usas), crea la base de datos y las carpetas
de Drive, y comprueba cada paso antes del siguiente.

**5. Instala el puente de Google Apps Script** cuando Claude lo pida. Es un archivo que
se ejecuta en tu cuenta de Google cada 15 minutos, aunque Claude no esté funcionando
(nombres de botones en inglés; Google puede mostrarlos en español):

- script.google.com → **New project** → pega el código que te muestra Claude → guarda;
- **Project Settings** → **Script Properties** → añade `SUPABASE_URL` y
  `SUPABASE_SECRET_KEY` (Claude te dice dónde encontrarlos; la clave va solo ahí, nunca en
  un chat);
- elige la función `install` → **Run** → **Review permissions** → tu cuenta → «Google
  hasn't verified this app» → **Advanced** → **Go to Life OS bridge (unsafe)** →
  **Select all** → **Allow**. El aviso es normal: es tu propio script y solo se ejecuta
  en tu cuenta.

Paso a paso, con la explicación de cada permiso (en inglés):
[docs/apps-script.md](docs/apps-script.md).

**6. Deja que funcione cada noche.** Claude no arranca solo, así que crea cuatro
ejecuciones programadas, mejor de noche y en este orden: correo a las **01:05**, archivos
a las **02:05**, la comprobación nocturna con tu resumen diario a las **03:05** y la
revisión mensual el día 1 a las **04:05**. El correo primero, porque su clasificación le
dice al puente qué adjuntos copiar; los archivos una hora después los indexan esa misma
noche; la comprobación al final, para que el resumen de la mañana lo incluya todo. Créalas como tareas programadas en Claude, cada una con el prompt de
[docs/scheduling.md](docs/scheduling.md) (en inglés).

Eso es todo, unos 30 minutos. Más adelante, en cualquier momento, escribe
**`life os doctor`**: revisa todo el sistema y te dice exactamente qué arreglar.

**Actualizar:** descarga el nuevo `life-os.zip` y súbelo de la misma forma (si Claude no
sustituye el skill, borra antes el antiguo). Después escribe `life os doctor`: aplica él
mismo las actualizaciones de la base de datos y las reglas nuevas.


### Qué necesitas

- Una cuenta de Google (Gmail y Google Drive).
- Un plan de Claude con skills y conectores.
- Una cuenta gratuita de [Supabase](https://supabase.com). Supabase es la base de datos
  donde vive el índice; el plan gratuito basta. Claude crea el proyecto por ti.
- Opcional: Todoist para tareas, Craft para el informe mensual. Sin ellos, las tareas y
  los informes llegan por correo y como Google Docs.

## Qué hace por ti

- **Cada noche** lee el correo nuevo, lo clasifica en 10 categorías (facturas,
  administraciones, banco, contratos, viajes, etc.), extrae importes y fechas de pago, y
  crea una tarea cuando tienes que actuar. Viajes y citas se convierten en eventos del
  calendario.
- **Los adjuntos importantes** (facturas, contratos, cartas de la administración) se
  copian automáticamente a Google Drive, se archivan en la carpeta correcta y se indexan
  con su texto completo.
- **Sigue plazos, no solo fechas.** Un permiso de residencia que caduca; una resolución
  que se puede recurrir durante un mes; un seguro que se renueva solo si no lo cancelas
  tres meses antes: cada uno se convierte en un plazo con recordatorios cada vez más
  frecuentes. Cómo se calcula un plazo depende de tu país.
- **Un breve resumen diario**, solo los días en que algo importa. Nunca un «todo bien».
- **Una revisión mensual**: cuánto pagas cada mes, qué ha cambiado, qué puedes cancelar y
  hasta cuándo, qué va en tu declaración de la renta y qué parece raro.
- **Una carpeta de emergencia**: un Google Doc reescrito cada día con tus asuntos
  abiertos, plazos, contratos, seguros, dónde están los originales y a quién llamar.

## Tareas en tu gestor de tareas

La base de datos lleva la lista; el gestor de tareas solo la refleja, así que no se
pierde nada si cambias de app o no usas ninguna. Con Todoist recibes:

| Tarea | Cuándo |
|---|---|
| `📅 Daily brief <fecha>: <lo más importante>` | solo los días en que algo importa; el resumen está en la descripción |
| `💌 <categoría> <remitente>: <qué hacer>` | una carta requiere una acción |
| `⚠️ <documento> expires <fecha>: <archivo>` | un documento caduca en 30 días |
| `🧾 Review <mes>: <decisión principal>` | una vez al mes, las decisiones que solo tú puedes tomar |
| `⚠️ <tarea> failed <fecha>` | una ejecución nocturna tuvo errores |

Los títulos están en el idioma que elijas; las palabras `Daily brief` se quedan en inglés
porque así el sistema reconoce su propio resumen. Completar una tarea cierra el plazo que
hay detrás. Más en [docs/tasks.md](docs/tasks.md) (en inglés).

## Ajustes

Todos los ajustes están en una tabla de tu propia base de datos, `life_settings`, y cada
cambio queda registrado en `settings_history`, visible y reversible. Para cambiar algo,
dilo: «cambia el idioma a inglés», «me he mudado a Alemania», «añade a mi hermana a la
carpeta de emergencia». Cuando cambian tu país o sus reglas, los plazos ya calculados se
recalculan, después de que Claude te muestre qué se mueve. Detalles en
[docs/settings.md](docs/settings.md) (en inglés).

## Idiomas y países

El sistema lee correo en cualquier idioma. Sus propios textos (resúmenes, tareas,
informes, carpeta de emergencia, nombres de carpetas) están en estos idiomas:

| Idioma | Estado |
|---|---|
| English, Deutsch, Українська | completos y probados |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | traducción inicial, inglés donde falta |

Las normas legales (cómo se cuenta un plazo de recurso, cuándo se puede cancelar un
contrato, hasta cuándo devolver una compra, cuándo presentar la declaración) vienen en un
**paquete regional**:

| País | Estado |
|---|---|
| 🇩🇪 Alemania | completo y probado |
| 🇦🇹 🇫🇷 🇪🇸 🇮🇹 🇳🇱 🇵🇹 🇵🇱 🇬🇧 🇺🇸 🇺🇦 Austria, Francia, España, Italia, Países Bajos, Portugal, Polonia, Reino Unido, Estados Unidos, Ucrania | beta: escrito a partir de las leyes citadas en cada regla, aún sin revisar sobre el terreno |

En el resto de países el sistema sigue cada fecha que lee, pero usa valores prudentes y
te pregunta por las normas locales. Las correcciones a los paquetes beta o un país nuevo
son muy bienvenidas: [packs/README.md](packs/README.md).

## Privacidad y seguridad

Tus datos se quedan en tus propias cuentas: tu Gmail, tu Drive, tu proyecto de Supabase.
No hay ningún servidor intermedio y nadie más tiene acceso. La base está cerrada de modo
que su interfaz pública no devuelve nada; solo Claude (a través de tu propio conector) y
tu propio Apps Script pueden leerla. Los archivos nunca pasan por la IA: Google los mueve
directamente de Gmail a Drive. Detalles en [docs/security.md](docs/security.md) (en
inglés).

## Cómo funciona

Todo lo que tiene que pasar a tiempo lo hacen cosas que no olvidan: Google Apps Script
cada 15 minutos y tareas programadas dentro de la base de datos cada noche. Claude solo
hace lo que requiere criterio: leer una carta y entender qué significa. La base de datos
es la única fuente de verdad; Todoist, Craft y el calendario solo la reflejan.

- [docs/architecture.md](docs/architecture.md): componentes, modelo de datos, el recorrido de una carta.
- [docs/apps-script.md](docs/apps-script.md): instalar el puente.
- [docs/scheduling.md](docs/scheduling.md): el horario nocturno: horas, orden.
- [docs/tasks.md](docs/tasks.md): qué llega al gestor de tareas y cómo se cierra.
- [docs/settings.md](docs/settings.md): todos los ajustes y qué pasa cuando cambia uno.
- [docs/security.md](docs/security.md): claves, permisos, qué ve la IA, copias de seguridad.
- [docs/troubleshooting.md](docs/troubleshooting.md): cada fallo del original y cómo se arregla.

## Estado

Temprano. La base de datos, el puente y el procesamiento de correo funcionaron a diario
durante un mes en la versión privada original y después se generalizaron. El skill de
instalación y los paquetes son nuevos. Habrá asperezas; por favor, infórmalas.
