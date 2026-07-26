# Agents.md

> Reglas de operación para todos los agentes de IA que trabajen en este repo.
> Se lee PRIMERO, siempre, antes de tocar código.

## Propósito

<!-- COMPLETAR: alcance de este archivo y a quién obliga (todos los agentes y humanos que commitean). -->

Este archivo define cómo se trabaja en el repo. Su cumplimiento es condición para
cerrar cualquier tarea.

## Reglas duras (no negociables)

- **Rama de trabajo:** <!-- COMPLETAR: p.ej. todo el trabajo va a `develop`; `main` solo por merge tras validación. -->
- **Nada se borra:** todo contenido obsoleto (código o docs) se archiva en `old/`
  (o `docs/old/`) con `git mv`. Nunca `rm`.
- **Requiere aprobación humana explícita:** migraciones de base de datos, cambios
  de esquema, manejo de credenciales/secretos, y deploy a producción.
- **Nunca se commitean secretos** ni valores reales de entorno.

## Protocolo de arranque

Orden obligatorio de lectura antes de escribir código:

1. `Agents.md` (este archivo)
2. `ProductDescription.md`
3. `Stack_Tecnologies.md`
4. `Features.md`
5. `Roadmap.md`
6. Últimas 20 entradas de `Agentslog.md`

## Protocolo de cierre

Antes de dar una tarea por terminada, actualizar según corresponda:

- `Roadmap.md` (estado de la tarea; mover a `Features.md` si quedó completa).
- `Features.md` (si se completó y testeó una funcionalidad).
- `Stack_Tecnologies.md` (si cambiaron deps, entidades o decisiones técnicas).
- `Agentslog.md` (**siempre**: una entrada por cada cambio de código).
- Correr `scripts/check_docs.sh` y que dé exit code 0.

## Trabajo colaborativo multi-agente

- Para tomar una tarea del `Roadmap.md`: marcarla `EN CURSO` con `<ID-agente>` y
  timestamp. Otro agente no toma una tarea `EN CURSO`.
- Para evitar trabajo pisado: verificar en `Agentslog.md` qué se tocó recientemente.
- Ante conflicto de criterios: registrar **ambas** opciones en `Agentslog.md` y
  escalar al humano. No decidir en silencio ni pisar la decisión del otro agente.

## Convenciones de código y commits

- <!-- COMPLETAR: estilo de código, linter/formatter, convención de nombres. -->
- <!-- COMPLETAR: formato de mensajes de commit (p.ej. Conventional Commits). -->
- Idioma: documentación en español; código/variables/commits en inglés (salvo
  indicación contraria acá).

## Prohibido

- Inventar dependencias, librerías, endpoints o entidades que no existen.
- Cambiar decisiones técnicas ya registradas en `Stack_Tecnologies.md` sin dejar
  constancia (nueva fila en la tabla de decisiones + entrada en `Agentslog.md`).
- Borrar o deshabilitar tests para "hacer pasar" una tarea.
- Commitear secretos, tokens o credenciales.
