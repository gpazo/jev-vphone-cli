@testable import vphone_cli
import Foundation
import Testing

struct RemoteProviderTests {
    let account = String(repeating: "a", count: 32)
    let result = #"{"model":"clef","answers":{"action":{"type":"choice","choice":"finish","confidence":0.9,"probabilities":{"finish":0.95,"wait":0.05}},"done":{"type":"noul","noul":0.99}},"usage":{"input_tokens":42,"output_tokens":0}}"#

    @Test func defaultProviderKeepsTypeSafeTransport() throws {
        let client = try VPhoneJevClient(environment: ["TYPESAFE_API_KEY": "test-jev"])
        let request = try client.makeRequest(state: ["goal": "test"], questions: ["done": .noul("Done?")])
        #expect(client.provider == .typesafe)
        #expect(client.cloudflareAccountID == nil)
        #expect(client.model == "jev-latest")
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-jev")
        #expect(request.httpMethod == "POST")
        #expect(try client.decodeResponse(Data(result.utf8), status: 200).usage?.inputTokens == 42)
    }

    @Test(arguments: ["clef", "clef-flash"])
    func cloudflareUsesMatchingEndpointModelAndOwnKey(model: String) throws {
        let client = try VPhoneJevClient(model: model, provider: .cloudflare, environment: [
            "TYPESAFE_API_KEY": "wrong-provider", "CLOUDFLARE_API_TOKEN": "test-cf", "CLOUDFLARE_ACCOUNT_ID": account,
        ])
        let request = try client.makeRequest(state: ["goal": "test"], questions: ["done": .noul("Done?")])
        #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/@cf/cloudflare/\(model)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-cf")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == model)
        #expect(client.cloudflareAccountID == account)
        #expect(payload["state"] as? [String: String] == ["goal": "test"])
        #expect(!String(decoding: body, as: UTF8.self).contains("test-cf"))
    }

    @Test func cloudflareEnvelopePreservesAnswersAndUsage() throws {
        let client = try VPhoneJevClient(apiKey: "test", provider: .cloudflare, accountID: account, environment: [:])
        let data = Data("{\"success\":true,\"errors\":[],\"result\":\(result)}".utf8)
        let response = try client.decodeResponse(data, status: 200)
        #expect(response["action"]?.validated(against: ["finish", "wait"]) == nil)
        #expect(response["done"]?.noul == 0.99)
        #expect(response.usage?.inputTokens == 42)
    }

    @Test func invalidEnvelopesAndHTTPFailuresCannotBecomeDecisions() throws {
        let client = try VPhoneJevClient(apiKey: "secret-value", provider: .cloudflare, accountID: account, environment: [:])
        for body in [result, #"{"success":true,"errors":[],"result":null}"#,
                     #"{"success":false,"errors":[{"code":10000,"message":"denied"}],"result":null}"#,
                     "{\"success\":true,\"errors\":[{\"code\":1,\"message\":\"bad\"}],\"result\":\(result)}"] {
            #expect(throws: (any Error).self) { try client.decodeResponse(Data(body.utf8), status: 200) }
        }
        do {
            _ = try client.decodeResponse(Data("secret-value".utf8), status: 403)
            Issue.record("HTTP failure was accepted")
        } catch {
            #expect(String(describing: error).contains("403"))
            #expect(!String(describing: error).contains("secret-value"))
        }
    }

    @Test func configurationFailsBeforeNetworkAndNeverSharesCredentials() throws {
        #expect(throws: (any Error).self) {
            try VPhoneJevClient(provider: .cloudflare, accountID: account, environment: ["TYPESAFE_API_KEY": "jev-only"])
        }
        #expect(throws: (any Error).self) {
            try VPhoneJevClient(apiKey: "test", provider: .cloudflare, accountID: "../other?", environment: [:])
        }
        #expect(throws: (any Error).self) {
            try VPhoneJevClient(apiKey: "test", model: "jev-latest", provider: .cloudflare, accountID: account, environment: [:])
        }
        let alias = try VPhoneJevClient(provider: .cloudflare, accountID: account,
            environment: ["CLOUDFLARE_AUTH_TOKEN": "alias"])
        #expect(alias.model == "clef")
    }

    @Test func cliSelectsProviderWithoutChangingPolicyOptions() throws {
        let command = try VPhoneJevCommand.parse(["open Settings", "--provider", "cloudflare", "--model", "clef-flash"])
        #expect(command.provider == .cloudflare)
        #expect(command.model == "clef-flash")
        #expect(!command.compactRequests)
        #expect(!command.validateForms)
        #expect(command.planner == nil)
        #expect(throws: (any Error).self) { try VPhoneJevCommand.parse(["open Settings", "--provider", "unknown"]) }
    }
}
