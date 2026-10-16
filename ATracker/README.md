# Atracker: iPhone, Apple Watch y servidor Oracle

Registra en tu base de datos **Atracker** de Notion (Académico › Universidad › UOC › Bases de datos Universidad › Atracker)
los minutos que dedicas a cada asignatura.

```
Apple Watch ──┐                          ┌──> Notion: Asignaturas / PECS (lectura)
              ├─ HTTPS + código acceso ─> │ servidor Oracle (FastAPI)
iPhone ───────┘                          └──> Notion: Atracker (escribe los minutos)
```

- **iPhone**: eliges una asignatura (de tu base de datos *Asignaturas*, filtrada por *Curso académico*), qué estás haciendo
  (**PEC**, **Apuntes** o **Estudiar**), la etiqueta de *Tareas* y la página de *PECS* relacionada. Esas tareas se envían al reloj.
- **Apple Watch**: muestra la lista, pulsas una tarea → **Iniciar** / **Parar y guardar**. Al parar se redondea a minutos y se envía al servidor.
- **Servidor** (`server/`): el único que tiene el token de Notion. Las apps solo conocen la URL del servidor y tu código de acceso.

## Qué escribe en Notion

| Propiedad Atracker | Valor |
|---|---|
| Nombre | `Registro Atracker` |
| Minutos | minutos cronometrados (redondeados; menos de 30 s no se guarda) |
| Fecha | día en que empezó el temporizador |
| Tareas | PEC → `PEC 1…5` · Apuntes → `Módulo 1…5` · Estudiar → `Examen` o `Módulo 1…5` |
| Asignatura | relación con la asignatura elegida |
| PEC | relación con la página de PECS elegida (PEC, «Apuntes …» o «Examen …») |

Con **Sumar al registro del día** (Ajustes, activado por defecto), si ya existe un registro de ese día con la misma
asignatura, tarea y PEC, el servidor suma los minutos a ese registro en vez de crear otro.
Cada registro lleva un identificador: si la app reintenta un envío, el servidor no lo cuenta dos veces.

Si el reloj no tiene conexión, pasa el registro al iPhone, que lo envía en cuanto puede (Ajustes › Pendientes de subir).

## 1. Integración de Notion

1. <https://www.notion.so/my-integrations> → **Nueva integración** interna (leer, insertar y actualizar contenido).
   Puedes reutilizar la de otra app si ya tiene acceso.
2. En Notion, en cada base de datos → **•••** → **Conexiones** → añade la integración: **Atracker**, **Asignaturas** y **PECS**.

## 2. Servidor en Oracle

API (todas menos `/health` piden `Authorization: Bearer <código>`):

| Método | Ruta | Para qué |
|---|---|---|
| GET | `/health` | comprobar que está vivo |
| GET | `/subjects?course=2026/27` | asignaturas del curso |
| GET | `/subjects/{id}/pecs` | páginas de PECS de una asignatura |
| POST | `/entries` | `{id, subject_id, tag, pec_id, minutes, day, accumulate}` → `{total, duplicate}` |

Pasos (desde la Terminal de tu Mac; ve uno a uno y comprueba la salida antes de seguir):

**2.1 Inspeccionar cómo están tus otras apps** (no cambia nada):

```bash
ssh ubuntu@IP_DEL_SERVIDOR
systemctl list-units --type=service --state=running | grep -v systemd
sudo ss -tlnp | grep LISTEN          # puertos ocupados
ls /etc/nginx/sites-enabled 2>/dev/null; ls /etc/caddy 2>/dev/null   # proxy HTTPS
```

Con eso decidimos: usuario y carpeta (igual que tus otras apps), un puerto libre (por defecto `8010`)
y cómo publicar `/atracker` por HTTPS en el proxy que ya uses. iOS exige HTTPS.

**2.2 Copiar el código** (desde el Mac):

```bash
scp -r ATracker/server ubuntu@IP_DEL_SERVIDOR:~/atracker
```

**2.3 Instalar y configurar** (en el servidor):

```bash
cd ~/atracker
python3 -m venv venv && venv/bin/pip install -r requirements.txt
cp .env.example .env && chmod 600 .env
openssl rand -hex 24        # este será tu código de acceso
nano .env                   # pega NOTION_TOKEN y ATRACKER_ACCESS_CODE
```

**2.4 Probar a mano antes del servicio**:

```bash
set -a; . ./.env; set +a
venv/bin/uvicorn main:app --host 127.0.0.1 --port 8010 &
curl -s localhost:8010/health
curl -s -H "Authorization: Bearer $ATRACKER_ACCESS_CODE" "localhost:8010/subjects?course=2026/27" | head -c 400
kill %1
```

Si ves tus asignaturas, la conexión con Notion funciona.

**2.5 Servicio permanente**: revisa `User`, rutas y puerto en `atracker.service`, y luego:

```bash
sudo cp atracker.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now atracker
systemctl status atracker --no-pager
journalctl -u atracker -n 30 --no-pager
```

**2.6 HTTPS**: añade en tu proxy una ruta `/atracker/` → `http://127.0.0.1:8010/`. Ejemplo para nginx, dentro del `server { … }` con HTTPS:

```nginx
location /atracker/ {
    proxy_pass http://127.0.0.1:8010/;
    proxy_set_header Host $host;
}
```

`sudo nginx -t && sudo systemctl reload nginx`, y prueba desde el Mac: `curl -s https://TU_DOMINIO/atracker/health`.

Pruebas automáticas del servidor (con un Notion simulado): `pip install pytest && python -m pytest tests`.

## 3. Crear el proyecto en Xcode (Mac)

1. Xcode → **File › New › Project… › watchOS › App** → *Watch App with New Companion iOS App*.
   Nombre: `ATracker`, interfaz SwiftUI.
2. Borra los `ContentView.swift` y `…App.swift` que genera Xcode en los dos targets.
3. Arrastra las carpetas al proyecto:
   - `Shared/` → marca **los dos** targets (iOS y Watch).
   - `iOS/` → solo el target iOS.
   - `Watch/` → solo el target Watch.
4. Deployment target: **iOS 17** y **watchOS 10** o superior.
5. Si Xcode muestra errores de concurrencia (Swift 6 / *Default Actor Isolation*): en *Build Settings* de ambos targets pon
   **Swift Language Version = Swift 5** y **Default Actor Isolation = nonisolated**.
6. Elige tu equipo en *Signing & Capabilities* y ejecuta en el iPhone; la app del reloj se instala con ella.

## 4. Uso

1. iPhone → **Ajustes**: URL del servidor (p. ej. `https://TU_DOMINIO/atracker`) y código de acceso → *Probar conexión*.
2. iPhone → **Tareas** → **+**: asignatura, tipo (PEC / Apuntes / Estudiar), etiqueta y página de PECS (se sugiere sola).
3. Reloj: abre Atracker, toca la tarea → **Iniciar**. Cuando acabes → **Parar y guardar**.
   El tiempo sigue contando aunque salgas de la app (se guarda la hora de inicio).

## Archivos

```
server/   main.py (API), notion.py (Notion), tests/, requirements.txt, .env.example, atracker.service
Shared/   Models.swift, APIClient.swift (cliente del servidor), Stores.swift (ajustes, tareas, cola), Connectivity.swift (iPhone⇄Watch)
iOS/      ATrackerApp.swift, TasksView.swift (lista + alta de tareas), SettingsView.swift
Watch/    ATrackerWatchApp.swift, TaskListView.swift (lista + temporizador), TimerStore.swift
```
