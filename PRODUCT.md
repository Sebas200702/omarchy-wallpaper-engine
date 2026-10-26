# Product

<!-- impeccable:product-schema 1 -->

## Platform

linux desktop

## Users

Personas que usan Omarchy en escritorio y quieren explorar, aplicar y organizar fondos de imagen o video sin salir del entorno.

## Product Purpose

WallHub (antes Wallpaper Engine for Omarchy) reúne fondos locales, favoritos, listas y fuentes en línea en una galería. La tarea principal de la pantalla es encontrar y aplicar un fondo con rapidez.

## Positioning

El mismo panel integra búsqueda en Wallhaven, MoeWalls y Steam Workshop con la biblioteca local, reproducción, rotación y asignación por monitor.

## Operating Context

Complemento de Omarchy Shell basado en Quickshell y QML. Se abre desde la barra o mediante `omarchy-shell shell summon io.github.sebas200702.wallhub`. Comparte espacio con el escritorio y opera con teclado y ratón.

## Capabilities and Constraints

- Biblioteca local de imágenes y videos, favoritos, listas, filtros y selección múltiple.
- Búsqueda en línea con descarga al aplicar; algunos resultados ofrecen vista previa de video.
- Rotación, horarios, reproducción consciente de batería e inactividad, y fondos fijados por monitor.
- La revisión de la galería conserva funciones existentes, pero reemplaza su estética y prioriza explorar y aplicar.
- Objetivo solicitado: mejorar rendimiento de carga, desplazamiento, vistas previas y respuesta de controles. No hay una meta numérica acordada.
- La interfaz debe funcionar en resoluciones de escritorio distintas y con escalado del compositor.

## Evidence on Hand

- Código actual: `Panel.qml`, `Service.qml`, `wallpaper-engine.sh` y `providers/`.
- Captura del panel anterior aportada por el usuario en esta conversación.
- Suite local: `tests/run.sh`.

## Product Principles

- La imagen es el contenido principal; los controles aparecen cuando aportan una decisión.
- Aplicar el fondo seleccionado debe ser inmediato y claro.
- Las funciones avanzadas siguen disponibles sin ocupar la vista de exploración.
- El coste de renderizado crece con lo visible, no con toda la biblioteca.

## Brand Commitments

- Combinar la integración y sobriedad de Omarchy con el lenguaje editorial del sistema visual AniDev aportado por el usuario en `~/Downloads/AniDev Design System-png/`.
- Tomar de AniDev la tipografía geométrica para títulos, etiquetas mono, líneas finas, superficies casi negras y una sola señal de acento; conservar los colores activos del tema Omarchy cuando corresponda.
- Mantener las imágenes de cada wallpaper como elemento protagonista. Evitar que una columna permanente de controles reduzca el espacio de exploración.
