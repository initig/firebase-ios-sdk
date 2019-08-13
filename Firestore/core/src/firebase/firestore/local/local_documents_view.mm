/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/core/src/firebase/firestore/local/local_documents_view.h"

#include <string>
#include <utility>

#import "Firestore/Source/Model/FSTMutation.h"
#import "Firestore/Source/Model/FSTMutationBatch.h"

#include "Firestore/core/src/firebase/firestore/local/mutation_queue.h"
#include "Firestore/core/src/firebase/firestore/local/remote_document_cache.h"
#include "Firestore/core/src/firebase/firestore/model/document.h"
#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/src/firebase/firestore/model/document_map.h"
#include "Firestore/core/src/firebase/firestore/model/no_document.h"
#include "Firestore/core/src/firebase/firestore/model/resource_path.h"
#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"

NS_ASSUME_NONNULL_BEGIN

namespace firebase {
namespace firestore {
namespace local {

using core::Query;
using model::Document;
using model::DocumentKey;
using model::DocumentKeySet;
using model::DocumentMap;
using model::MaybeDocument;
using model::MaybeDocumentMap;
using model::NoDocument;
using model::OptionalMaybeDocumentMap;
using model::ResourcePath;
using model::SnapshotVersion;
using util::MakeString;

absl::optional<MaybeDocument> LocalDocumentsView::GetDocument(
    const DocumentKey& key) {
  std::vector<FSTMutationBatch*> batches =
      mutation_queue_->AllMutationBatchesAffectingDocumentKey(key);
  return GetDocument(key, batches);
}

absl::optional<MaybeDocument> LocalDocumentsView::GetDocument(
    const DocumentKey& key, const std::vector<FSTMutationBatch*>& batches) {
  absl::optional<MaybeDocument> document = remote_document_cache_->Get(key);
  for (FSTMutationBatch* batch : batches) {
    document = [batch applyToLocalDocument:document documentKey:key];
  }

  return document;
}

OptionalMaybeDocumentMap LocalDocumentsView::ApplyLocalMutationsToDocuments(
    const OptionalMaybeDocumentMap& docs,
    const std::vector<FSTMutationBatch*>& batches) {
  OptionalMaybeDocumentMap results;

  for (const auto& kv : docs) {
    const DocumentKey& key = kv.first;
    absl::optional<MaybeDocument> local_view = kv.second;
    for (FSTMutationBatch* batch : batches) {
      local_view = [batch applyToLocalDocument:local_view documentKey:key];
    }
    results = results.insert(key, local_view);
  }
  return results;
}

MaybeDocumentMap LocalDocumentsView::GetDocuments(const DocumentKeySet& keys) {
  OptionalMaybeDocumentMap docs = remote_document_cache_->GetAll(keys);
  return GetLocalViewOfDocuments(docs);
}

/**
 * Similar to `documentsForKeys`, but creates the local view from the given
 * `baseDocs` without retrieving documents from the local store.
 */
MaybeDocumentMap LocalDocumentsView::GetLocalViewOfDocuments(
    const OptionalMaybeDocumentMap& base_docs) {
  DocumentKeySet all_keys;
  for (const auto& kv : base_docs) {
    all_keys = all_keys.insert(kv.first);
  }
  std::vector<FSTMutationBatch*> batches =
      mutation_queue_->AllMutationBatchesAffectingDocumentKeys(all_keys);

  OptionalMaybeDocumentMap docs =
      ApplyLocalMutationsToDocuments(base_docs, batches);

  MaybeDocumentMap results;
  for (const auto& kv : docs) {
    const DocumentKey& key = kv.first;
    absl::optional<MaybeDocument> maybe_doc = kv.second;

    // TODO(http://b/32275378): Don't conflate missing / deleted.
    if (!maybe_doc) {
      maybe_doc = NoDocument(key, SnapshotVersion::None(),
                             /* has_committed_mutations= */ false);
    }
    results = results.insert(key, *maybe_doc);
  }

  return results;
}

DocumentMap LocalDocumentsView::GetDocumentsMatchingQuery(const Query& query) {
  if (query.IsDocumentQuery()) {
    return GetDocumentsMatchingDocumentQuery(query.path());
  } else if (query.IsCollectionGroupQuery()) {
    return GetDocumentsMatchingCollectionGroupQuery(query);
  } else {
    return GetDocumentsMatchingCollectionQuery(query);
  }
}

DocumentMap LocalDocumentsView::GetDocumentsMatchingDocumentQuery(
    const ResourcePath& doc_path) {
  DocumentMap result;
  // Just do a simple document lookup.
  absl::optional<MaybeDocument> doc = GetDocument(DocumentKey{doc_path});
  if (doc && doc->is_document()) {
    result = result.insert(doc->key(), Document(*doc));
  }
  return result;
}

model::DocumentMap LocalDocumentsView::GetDocumentsMatchingCollectionGroupQuery(
    const Query& query) {
  HARD_ASSERT(
      query.path().empty(),
      "Currently we only support collection group queries at the root.");

  const std::string& collection_id = *query.collection_group();
  std::vector<ResourcePath> parents =
      index_manager_->GetCollectionParents(collection_id);
  DocumentMap results;

  // Perform a collection query against each parent that contains the
  // collection_id and aggregate the results.
  for (const ResourcePath& parent : parents) {
    Query collection_query =
        query.AsCollectionQueryAtPath(parent.Append(collection_id));
    DocumentMap collection_results =
        GetDocumentsMatchingCollectionQuery(collection_query);
    for (const auto& kv : collection_results.underlying_map()) {
      const DocumentKey& key = kv.first;
      results = results.insert(key, Document(kv.second));
    }
  }
  return results;
}

DocumentMap LocalDocumentsView::GetDocumentsMatchingCollectionQuery(
    const Query& query) {
  DocumentMap results = remote_document_cache_->GetMatching(query);
  // Get locally persisted mutation batches.
  std::vector<FSTMutationBatch*> matchingBatches =
      mutation_queue_->AllMutationBatchesAffectingQuery(query);

  results = AddMissingBaseDocuments(matchingBatches, std::move(results));

  for (FSTMutationBatch* batch : matchingBatches) {
    for (FSTMutation* mutation : [batch mutations]) {
      // Only process documents belonging to the collection.
      if (!query.path().IsImmediateParentOf(mutation.key.path())) {
        continue;
      }

      const DocumentKey& key = mutation.key;
      // base_doc may be unset for the documents that weren't yet written to
      // the backend.
      absl::optional<MaybeDocument> base_doc;
      auto found = results.underlying_map().find(key);
      if (found != results.underlying_map().end()) {
        base_doc = found->second;
      }

      absl::optional<MaybeDocument> mutated_doc =
          [mutation applyToLocalDocument:base_doc
                            baseDocument:base_doc
                          localWriteTime:batch.localWriteTime];

      if (mutated_doc && mutated_doc->is_document()) {
        results = results.insert(key, Document(*mutated_doc));
      } else {
        results = results.erase(key);
      }
    }
  }

  // Finally, filter out any documents that don't actually match the query. Note
  // that the extra reference here prevents DocumentMap's destructor from
  // deallocating the initial unfiltered results while we're iterating over
  // them.
  DocumentMap unfiltered = results;
  for (const auto& kv : unfiltered.underlying_map()) {
    const DocumentKey& key = kv.first;
    Document doc(kv.second);
    if (!query.Matches(doc)) {
      results = results.erase(key);
    }
  }

  return results;
}

DocumentMap LocalDocumentsView::AddMissingBaseDocuments(
    const std::vector<FSTMutationBatch*>& matching_batches,
    DocumentMap existing_docs) {
  DocumentKeySet missing_doc_keys;
  for (FSTMutationBatch* batch : matching_batches) {
    for (FSTMutation* mutation : [batch mutations]) {
      if ([mutation isKindOfClass:[FSTPatchMutation class]] &&
          existing_docs.underlying_map().find([mutation key]) ==
              existing_docs.underlying_map().end()) {
        missing_doc_keys = missing_doc_keys.insert([mutation key]);
      }
    }
  }

  OptionalMaybeDocumentMap missing_docs =
      remote_document_cache_->GetAll(missing_doc_keys);
  for (const auto& kv : missing_docs) {
    const absl::optional<MaybeDocument>& maybe_doc = kv.second;
    if (maybe_doc && maybe_doc->is_document()) {
      existing_docs = existing_docs.insert(kv.first, Document(*maybe_doc));
    }
  }

  return existing_docs;
}

}  // namespace local
}  // namespace firestore
}  // namespace firebase

NS_ASSUME_NONNULL_END
