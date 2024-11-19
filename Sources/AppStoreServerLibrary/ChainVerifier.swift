// Copyright (c) 2023 Apple Inc. Licensed under MIT License.

import Foundation
import X509
import SwiftASN1
import JWTKit
import Crypto
import AsyncHTTPClient
import NIOFoundationCompat

struct ChainVerifier {
    
    private static let EXPECTED_CHAIN_LENGTH = 3
    private static let EXPECTED_JWT_SEGMENTS = 3
    private static let EXPECTED_ALGORITHM = "ES256"
    
    private let store: CertificateStore
    
    init(rootCertificates: [Foundation.Data]) throws {
        let parsedCertificates = try rootCertificates.map { try Certificate(derEncoded: [UInt8]($0)) }
        self.store = CertificateStore(parsedCertificates)
    }
    
    func verify<T: DecodedSignedData>(signedData: String, type: T.Type, onlineVerification: Bool, environment: Environment) async -> VerificationResult<T> where T: Decodable {
        let header: JWTHeader;
        let decodedBody: T;
        do {
            let bodySegments = signedData.components(separatedBy: ".")
            if (bodySegments.count != ChainVerifier.EXPECTED_JWT_SEGMENTS) {
                return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
            }
            let jsonDecoder = getJsonDecoder()
            guard let headerData = Foundation.Data(base64Encoded: base64URLToBase64(bodySegments[0])), let bodyData = Foundation.Data(base64Encoded: base64URLToBase64(bodySegments[1])) else {
                return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
            }
            header = try jsonDecoder.decode(JWTHeader.self, from: headerData)
            decodedBody = try jsonDecoder.decode(type, from: bodyData)
        } catch {
            return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
        }
        
        if (environment == Environment.xcode || environment == Environment.localTesting) {
            // Data is not signed by the App Store, and verification should be skipped
            // The environment MUST be checked in the public method calling this
            return VerificationResult.valid(decodedBody)
        }

        guard let x5c_header = header.x5c else {
            return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
        }
        if ChainVerifier.EXPECTED_ALGORITHM != header.alg || x5c_header.count != ChainVerifier.EXPECTED_CHAIN_LENGTH {
            return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
        }
        

        guard let leaf_der_enocded = Foundation.Data(base64Encoded: x5c_header[0]),
              let intermeidate_der_encoded = Foundation.Data(base64Encoded: x5c_header[1]) else {
            return VerificationResult.invalid(VerificationError.INVALID_CERTIFICATE)
        }
        do {
            let leafCertificate = try Certificate(derEncoded: Array(leaf_der_enocded))
            let intermediateCertificate = try Certificate(derEncoded: Array(intermeidate_der_encoded))
            let validationTime = !onlineVerification && decodedBody.signedDate != nil ? decodedBody.signedDate! : Date()
            
            let verificationResult = await verifyChain(leaf: leafCertificate, intermediate: intermediateCertificate, online: onlineVerification, validationTime: validationTime)
            switch verificationResult {
            case .validCertificate(let chain):
                let leafCertificate = chain.first!
                guard let publicKey = P256.Signing.PublicKey(leafCertificate.publicKey) else {
                    return VerificationResult.invalid(VerificationError.VERIFICATION_FAILURE)
                }
                // Verify using Vapor
                let keys = JWTKeyCollection()
                await keys.add(ecdsa: try ECDSA.PublicKey<P256>(backing: publicKey))
                let verifiedBody: VerificationResult<VaporBody> = try await VerificationResult<VaporBody>.valid(keys.verify(signedData))
                switch verifiedBody {
                    case .invalid(_):
                        return VerificationResult.invalid(VerificationError.VERIFICATION_FAILURE)
                    case .valid(_): break
                }
                return VerificationResult.valid(decodedBody)
            case .couldNotValidate(_):
                return VerificationResult.invalid(VerificationError.VERIFICATION_FAILURE)
            }
        } catch {
            return VerificationResult.invalid(VerificationError.INVALID_JWT_FORMAT)
        }
    }
    
    func verifyChain(leaf: Certificate, intermediate: Certificate, online: Bool, validationTime: Date) async -> X509.VerificationResult {
        var verifier = Verifier(rootCertificates: self.store) {
            RFC5280Policy(validationTime: validationTime)
            AppStoreOIDPolicy()
            if online {
                OCSPVerifierPolicy(failureMode: .hard, requester: Requester(), validationTime: Date())
            }
        }
        let intermediateStore = CertificateStore([intermediate])
        return await verifier.validate(leafCertificate: leaf, intermediates: intermediateStore)
    }
}

struct VaporBody : JWTPayload {
    func verify(using algorithm: some JWTAlgorithm) async throws {
        // No-op
    }
}

struct JWTHeader: Decodable, Encodable {
    public var alg: String?
    public var x5c: [String]?
}

final class AppStoreOIDPolicy: VerifierPolicy {
    
    private static let NUMBER_OF_CERTS = 3
    private static let WWDR_INTERMEDIATE_OID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 6, 2, 1]
    private static let RECEIPT_SIGNER_OID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 6, 11, 1]
    
    init() {
        verifyingCriticalExtensions = []
    }
    var verifyingCriticalExtensions: [SwiftASN1.ASN1ObjectIdentifier]
    
    func chainMeetsPolicyRequirements(chain: X509.UnverifiedCertificateChain) async -> X509.PolicyEvaluationResult {
        if (chain.count != AppStoreOIDPolicy.NUMBER_OF_CERTS) {
            return X509.PolicyEvaluationResult.failsToMeetPolicy(reason: "Chain has unexpected length")
        }
        let intermediateCertificate = chain[1]
        let leafCertificate = chain[0]
        if (!intermediateCertificate.extensions.contains(where: { ext in
            ext.oid == AppStoreOIDPolicy.WWDR_INTERMEDIATE_OID
        })) {
            return X509.PolicyEvaluationResult.failsToMeetPolicy(reason: "Intermediate certificate does not contain WWDR OID")
        }
        if (!leafCertificate.extensions.contains(where: { ext in
            ext.oid == AppStoreOIDPolicy.RECEIPT_SIGNER_OID
        })) {
            return X509.PolicyEvaluationResult.failsToMeetPolicy(reason: "Leaf certificate does not contain Receipt Signing OID")
        }
        return X509.PolicyEvaluationResult.meetsPolicy
    }
}

final class Requester: OCSPRequester {
    func query(request: [UInt8], uri: String) async -> X509.OCSPRequesterQueryResult {
        do {
            let httpClient = HTTPClient()
            defer {
                try? httpClient.syncShutdown()
            }
            var urlRequest = HTTPClientRequest(url: uri)
            urlRequest.method = .POST
            urlRequest.headers.add(name: "Content-Type", value: "application/ocsp-request")
            urlRequest.body = .bytes(request)
            let response = try await httpClient.execute(urlRequest, timeout: .seconds(30))
            var body = try await response.body.collect(upTo: 1024 * 1024)
            guard let data = body.readData(length: body.readableBytes) else {
                throw OCSPFetchError()
            }
            return .response([UInt8](data))
        } catch {
            return .terminalError(error)
        }
    }
    
    private struct OCSPFetchError: Error {}
}

public enum VerificationResult<T> {
    case valid(T)
    case invalid(VerificationError)
}

public enum VerificationError: Hashable, Sendable {
    case INVALID_JWT_FORMAT
    case INVALID_CERTIFICATE
    case VERIFICATION_FAILURE
    case INVALID_APP_IDENTIFIER
    case INVALID_ENVIRONMENT
}
