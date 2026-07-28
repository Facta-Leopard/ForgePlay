/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * Build-time identity boundary for the fixed ForgePlay Game Mode process host.
 * The build helper supplies every value from one validated Wine 11.12 runtime.
 */

#ifndef FORGEPLAY_GAME_MODE_BUILD_IDENTITY_H
#define FORGEPLAY_GAME_MODE_BUILD_IDENTITY_H

#ifndef FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER
#error "FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_APPLICATION_GROUP
#error "FORGEPLAY_GAME_MODE_APPLICATION_GROUP must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER
#error "FORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_RUNTIME_MANIFEST_SHA256
#error "FORGEPLAY_GAME_MODE_RUNTIME_MANIFEST_SHA256 must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT
#error "FORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_RUNTIME_CORE_FINGERPRINT
#error "FORGEPLAY_GAME_MODE_RUNTIME_CORE_FINGERPRINT must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_WINE_SOURCE_TREE_SHA256
#error "FORGEPLAY_GAME_MODE_WINE_SOURCE_TREE_SHA256 must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_WINE_PATCH_SET_SHA256
#error "FORGEPLAY_GAME_MODE_WINE_PATCH_SET_SHA256 must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_WINE_LOADER_SOURCE_SHA256
#error "FORGEPLAY_GAME_MODE_WINE_LOADER_SOURCE_SHA256 must be supplied by the host build"
#endif

#define FORGEPLAY_GAME_MODE_RUNTIME_SCHEMA_VERSION 3
#define FORGEPLAY_GAME_MODE_WINE_VERSION "11.12"
#define FORGEPLAY_GAME_MODE_RUNTIME_ARCHITECTURE "win64"

#endif
