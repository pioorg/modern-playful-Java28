/*
 * Copyright 2026 Marit van Dijk
 * Copyright 2026 Piotr Przybył
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
package org.przybyl;

import module java.base;
import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.SearchResponse;
import co.elastic.clients.elasticsearch.core.search.Hit;
import com.fasterxml.jackson.annotation.JsonProperty;
import jdk.incubator.json.Json;
import jdk.incubator.json.JsonArray;
import jdk.incubator.json.JsonObject;
import jdk.incubator.json.JsonString;

import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public class EnterpriseySearcher {

    private static final LazyConstant<HttpClient> HTTP_CLIENT = LazyConstant.of(() ->
        HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build());
    private static String ENCODER_URL = System.getenv().getOrDefault("ENCODER_URL", "http://localhost:8080/v1/embeddings");
    private static final int TOP_K = 5;

    public static void main(String[] args) {
//            List<String> queries = obtainQueries();
        List<String> queries = List.of("orange", "apple", "Heckscheibenwaschanlage", "computer", "basket", "jabłko", "appel");

        try (var esClient = ElasticsearchClient.of(b -> b
            .host(System.getenv("ES_URL"))
            .apiKey(System.getenv("ES_API_KEY")))) {

            runSearch(queries, esClient, "catalogue")
                .forEach(System.out::println);

        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    static List<String> obtainQueries() {
        List<String> queries = new ArrayList<>();
        String searchText;
        while (!(searchText = IO.readln("Enter text to search: ")).isBlank()) {
            queries.add(searchText);
        }
        return queries;
    }

    static List<SearchResult> runSearch(List<String> queries, ElasticsearchClient esClient, String indexName) {
        return queries.stream()
            .gather(Gatherers.mapConcurrent(5, query -> new QueryWithVector(query, obtainTextEmbedding(query))))
            .gather(Gatherers.mapConcurrent(5, qwv -> executeSearch(qwv, indexName, esClient)))
            .toList();
    }

    static SearchResult executeSearch(QueryWithVector qwv, String indexName, ElasticsearchClient esClient) {
        try (var scope = StructuredTaskScope.open(
            StructuredTaskScope.Joiner.awaitAllSuccessfulOrThrow(),
            config -> config
                .withName("searchSC")
                .withTimeout(Duration.ofSeconds(1))
        )) {
            var knnSearch = scope.fork(() -> performKnnSearch(qwv.vector(), indexName, esClient));
            var classicSearch = scope.fork(() -> performClassicSearch(qwv.query(), indexName, esClient));
            scope.join();
            var searchResults = combineUsingRRF(List.of(knnSearch.get(), classicSearch.get()), 60, TOP_K);
            return new SearchResult(qwv.query(), searchResults);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    static List<Float> obtainTextEmbedding(String text) {
        try {
//          {
//            "task" : "retrieval.query",
//            "input" : [ "apple" ]
//          }
            JsonObject requestBody = JsonObject.of(Map.of(
                "input", JsonArray.of(List.of(JsonString.of(text))),
                "task", JsonString.of("retrieval.query")));

            HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(ENCODER_URL))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(requestBody.toString()))
                .build();

            HttpResponse<String> response = HTTP_CLIENT.get().send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                throw new IOException("Failed to encode text [%s]. Status code: [%d], Response: [%s]"
                    .formatted(text, response.statusCode(), response.body()));
            }

//          {
//             "model":"jina-embeddings-v5-omni-nano",
//             "object":"list",
//             "usage":{
//                "total_tokens":2,
//                "prompt_tokens":2
//             },
//             "data":[
//                {
//                   "object":"embedding",
//                   "index":0,
//                   "embedding":[
//                      -0.0010152208851650357,
//                      ... ,
//                      0.002396837342530489
//                   ]
//                }
//             ]
//          }

            return Json.parse(response.body())
                .get("data")
                .get(0)
                .get("embedding")
                .asList()
                .stream()
                .map(jsonValue -> (float) jsonValue.asDouble())
                .toList();

        } catch (IOException | InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

    static List<CatalogueItem> performClassicSearch(String searchText, String indexName, ElasticsearchClient esClient) throws IOException {
        try {
            // First, check if the index exists
            checkTheIndexExists(esClient, indexName);

            // Build and execute the search request with a wildcard query to check if the filename contains searchText
            SearchResponse<CatalogueItem> response = esClient.search(s -> s
                    .index(indexName)
                    .query(q -> q
                        .wildcard(w -> w
                            .field("filename")
                            .wildcard("*" + searchText + "*")
                        )
                    )
                    .size(TOP_K)
                    .source(src -> src.filter(f -> f.includes("filename", "full-path", "price"))),
                CatalogueItem.class);

            return response.hits().hits().stream().map(Hit::source).toList();

        } catch (Exception e) {
            throw new IOException("Failed to perform BM25 search: " + e.getMessage(), e);
        }
    }

    /// Runs the vector search
    /// [See more](https://www.elastic.co/docs/solutions/search/vector/knn)
    static List<CatalogueItem> performKnnSearch(List<Float> queryVector, String indexName, ElasticsearchClient esClient) throws IOException {
        try {
            // First, check if the index exists
            checkTheIndexExists(esClient, indexName);

            // Set the number of desired nearest neighbors (k) and candidate oversampling factor
            int k = 5;
            int numCandidates = (int) (1.5 * k);

            // Build and execute the search request.
            // Note: The knn clause is added via the .knn() method.
            SearchResponse<CatalogueItem> response = esClient.search(s -> s
                    .index(indexName)
                    .knn(knn -> knn
                        .field("embedding")
                        .queryVector(queryVector)
                        .k(k)
                        .numCandidates(numCandidates)
                    )
                    // Also set the size of the search response to k
                    .size(k)
                    .source(src -> src.filter(f -> f.includes("filename", "full-path", "price"))),
                CatalogueItem.class);

            return response.hits().hits().stream().map(Hit::source).toList();

        } catch (Exception e) {
            throw new IOException("Failed to perform search: " + e.getMessage(), e);
        }
    }

    static void checkTheIndexExists(ElasticsearchClient esClient, String indexName) throws IOException {
        boolean indexExists = esClient.indices().exists(e -> e.index(indexName)).value();
        if (!indexExists) {
            throw new IOException("Index '" + indexName + "' does not exist");
        }
    }

    /// Merges results of various search algorithms
    /// [See more](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion)
    static List<CatalogueItem> combineUsingRRF(List<List<CatalogueItem>> searchResults, int k, int rankWindowSize) {
        // Create a map to store all unique items and their RRF scores
        Map<String, CatalogueItem> itemMap = new HashMap<>();
        Map<String, Double> rrfScores = new HashMap<>();

        // Process all search results
        for (List<CatalogueItem> resultList : searchResults) {
            for (int i = 0; i < resultList.size(); i++) {
                CatalogueItem item = resultList.get(i);
                int rank = i + 1; // Ranks start from 1
                double score = 1.0 / (k + rank);

                itemMap.put(item.fullPath(), item);
                // Add to existing score if item already exists, otherwise set a new score
                rrfScores.merge(item.fullPath(), score, Double::sum);
            }
        }

        // Sort items by their RRF scores in descending order
        return itemMap.values().stream()
            .sorted((a, b) -> Double.compare(rrfScores.get(b.fullPath()), rrfScores.get(a.fullPath())))
            .limit(rankWindowSize) // Limit to rankWindowSize results
            .toList();
    }

    // Allow setting the encoder URL for testing
    public static void setEncoderUrl(String url) {
        ENCODER_URL = url;
    }
}

value record QueryWithVector(String query, List<Float> vector) {

    @Override
    public String toString() {
        return "QueryWithVector[" +
            "query=" + query + ", " +
            "vector=[" + vector.getFirst()
            + ", ..., "
            + vector.getLast() + ']';
    }

}

value record Price(BigDecimal value, String currency) {
    @Override
    public String toString() {
        return value.setScale(2, RoundingMode.HALF_UP).toPlainString() + " " + currency;
    }
}

value record CatalogueItem(String filename, @JsonProperty("full-path") String fullPath, Price price) {
    public String toPriceString() {
        return String.format("%s (%s)", filename, formatPrice());
    }

    private String formatPrice() {
        if (price == null) {
            return "priceless";
        } else {
            return price.toString();
        }
    }
}

value record SearchResult(String query, List<CatalogueItem> items) {
    @Override
    public String toString() {
        return String.format("%s: %s", query, items().stream().map(CatalogueItem::toPriceString).toList());
    }
}
