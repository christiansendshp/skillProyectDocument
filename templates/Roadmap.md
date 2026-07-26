# Roadmap.md

> Seguimiento vivo del avance. Es el **único** lugar donde vive el trabajo
> pendiente. Toda funcionalidad nueva entra acá primero, desglosada, antes de
> escribir código.

## Cómo se usa

- Estructura jerárquica: **Funcionalidad → Subfunción → Tarea**.
- Cada tarea tiene ID único con el patrón `F01-S02-T03`.
- Estados: `PENDIENTE` · `EN CURSO` · `BLOQUEADO` · `LISTO PARA TEST` · `COMPLETADO`.
- Una tarea pasa a `COMPLETADO` **solo** cuando su criterio de aceptación está
  verificado con un test.
- Cuando una funcionalidad queda 100% completa y testeada, su resumen se **mueve**
  a `Features.md` y acá queda solo la referencia con link.
- En multi-agente: al tomar una tarea, marcarla `EN CURSO` con `<ID-agente>` y timestamp.

## Leyenda de estados

`PENDIENTE` → sin empezar · `EN CURSO` → tomada por un agente · `BLOQUEADO` →
espera una dependencia/decisión · `LISTO PARA TEST` → implementada, falta verificar ·
`COMPLETADO` → criterio de aceptación verificado con test.

## Funcionalidades

<!-- COMPLETAR: desglosar cada funcionalidad pedida. Ejemplo de estructura abajo. -->

### F01 — <!-- COMPLETAR: nombre de la funcionalidad -->

| ID | Descripción | Criterio de aceptación | Estado | Agente | Dependencias |
|---|---|---|---|---|---|
| F01-S01-T01 | <!-- COMPLETAR --> | <!-- COMPLETAR --> | PENDIENTE | — | — |

## Completadas (movidas a Features.md)

<!-- COMPLETAR: referencias con link a Features.md cuando una funcionalidad se cierra. -->
