// lib/data/services/semantic_search_api.dart
//
// DATA LAYER — SERVICE (REMOTE / API STUB)
// ------------------------------------------
// This service is the client-side half of a planned backend integration.
// It is NOT wired into the swipe flow yet — it's scaffolding so that when
// the Python backend exists, we only need to (a) point `baseUrl` at it and
// (b) start calling these methods from `swipe_provider.dart`. No UI or
// state-layer refactor should be required.
//
// -----------------------------------------------------------------------
// PLANNED BACKEND ARCHITECTURE (see README.md "Backend Vision" for more):
//
//   Flutter app  --(1) upload embeddings request)-->  FastAPI
//                                                         |
//                                                         v
//                                          SentenceTransformers model
//                                          encodes photo captions/tags
//                                          into vector embeddings
//                                                         |
//                                                         v
//                                                FAISS vector index
//                                          (stores + searches embeddings)
//
//   Flutter app  --(2) semantic query, e.g. "mountain treks")-->  FastAPI
//                                                         |
//                                    FAISS similarity search over index
//                                                         |
//   Flutter app  <--(matching asset IDs, ranked by similarity)--------
//
// The two methods below map directly onto steps (1) and (2).
// -----------------------------------------------------------------------

import 'dart:convert';
import 'package:http/http.dart' as http;

/// A single semantic search hit returned by the backend.
class SemanticSearchResult {
  SemanticSearchResult({required this.assetId, required this.score});

  /// The `photo_manager` asset ID this result corresponds to. The backend
  /// never sees or stores actual image bytes in this design — only
  /// metadata/embeddings keyed by the ID the client already owns.
  final String assetId;

  /// Cosine-similarity (or FAISS L2-derived) relevance score, higher is
  /// more relevant. Exposed so the UI can, e.g., fade out low-confidence
  /// matches instead of a hard cutoff.
  final double score;

  factory SemanticSearchResult.fromJson(Map<String, dynamic> json) {
    return SemanticSearchResult(
      assetId: json['asset_id'] as String,
      score: (json['score'] as num).toDouble(),
    );
  }
}

class SemanticSearchApi {
  SemanticSearchApi({
    this.baseUrl = 'https://your-fastapi-backend.example.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Base URL of the FastAPI backend. Left as a plain constructor
  /// parameter (rather than hardcoded) so it's trivial to point at
  /// localhost during development or swap per build flavor (dev/staging/
  /// prod) via dependency injection at the Riverpod provider level.
  final String baseUrl;

  final http.Client _client;

  /// STEP 1 — Upload metadata for embedding + indexing.
  ///
  /// Sends lightweight metadata (never raw image bytes, to keep payloads
  /// small and avoid shipping a user's photos to a server just to index
  /// them) that the backend can turn into a caption via an on-device or
  /// server-side image-captioning step, then embed with
  /// SentenceTransformers, then upsert into the FAISS index.
  ///
  /// [assetId] ties the embedding back to a local `photo_manager` asset.
  /// [caption] is an optional pre-computed description (e.g. from an
  /// on-device ML Kit label) — if omitted, the backend is expected to
  /// generate one itself from an uploaded thumbnail (future work).
  Future<void> uploadAssetMetadata({
    required String assetId,
    String? caption,
    DateTime? capturedAt,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/embeddings/upsert');

    // NOTE: This is a stub. Until the backend exists, this call is not
    // invoked anywhere in the app — it's here so the contract (endpoint
    // shape, payload keys) is documented and ready to flip on.
    await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'asset_id': assetId,
        'caption': caption,
        'captured_at': capturedAt?.toIso8601String(),
      }),
    );
  }

  /// STEP 2 — Semantic query against the FAISS index.
  ///
  /// Example: `semanticFilter("mountain treks")` should return the asset
  /// IDs of photos whose embeddings are nearest-neighbors to the query's
  /// embedding, letting the swipe queue be filtered down to just that
  /// theme (e.g. "only show me photos of mountain treks so I can decide
  /// which to keep").
  ///
  /// Returns an empty list (rather than throwing) on any network/parsing
  /// failure, so a not-yet-deployed backend degrades gracefully to
  /// "semantic filtering unavailable" instead of crashing the swipe flow.
  Future<List<SemanticSearchResult>> semanticFilter(
    String query, {
    int topK = 100,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/search').replace(queryParameters: {
      'q': query,
      'top_k': '$topK',
    });

    try {
      final response = await _client.get(uri);
      if (response.statusCode != 200) return const [];

      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      return body
          .map((e) => SemanticSearchResult.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Backend not deployed yet / network failure — fail soft.
      return const [];
    }
  }
}
