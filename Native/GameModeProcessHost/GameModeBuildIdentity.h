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

#ifndef FORGEPLAY_GAME_MODE_COORDINATION_PROFILE
#error "FORGEPLAY_GAME_MODE_COORDINATION_PROFILE must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY
#error "FORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY must be supplied by the host build"
#endif

#if FORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY != 0 && \
    FORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY != 1
#error "Game Mode production-identity state must be boolean"
#endif

#ifndef FORGEPLAY_GAME_MODE_HOST_RUNNABLE
#error "FORGEPLAY_GAME_MODE_HOST_RUNNABLE must be supplied by the host build"
#endif

#if FORGEPLAY_GAME_MODE_HOST_RUNNABLE != 0 && \
    FORGEPLAY_GAME_MODE_HOST_RUNNABLE != 1
#error "Game Mode host-runnable state must be boolean"
#endif

#ifndef FORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP
#error "FORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP must be supplied by the host build"
#endif

#ifndef FORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN
#error "FORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN must be supplied by the host build"
#endif

#if (FORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP + \
     FORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN) != 1
#error "exactly one Game Mode coordination profile must be selected"
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
