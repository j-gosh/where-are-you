//
//  Listening.swift
//  WAYFirebase
//

import FirebaseFirestore

/// Turns a snapshot listener into an `AsyncThrowingStream`. The listener is removed when the
/// stream's consumer goes away.
func listen<Value: Sendable>(to query: Query, map: @escaping @Sendable (QuerySnapshot) -> Value) -> AsyncThrowingStream<Value, Error> {
    AsyncThrowingStream { continuation in
        let registration = query.addSnapshotListener { snapshot, error in
            if let error {
                continuation.finish(throwing: error)
            } else if let snapshot {
                continuation.yield(map(snapshot))
            }
        }
        let handle = ListenerRegistrationHandle(registration: registration)
        continuation.onTermination = { _ in
            handle.registration.remove()
        }
    }
}

func listen<Value: Sendable>(to document: DocumentReference, map: @escaping @Sendable (DocumentSnapshot) throws -> Value) -> AsyncThrowingStream<Value, Error> {
    AsyncThrowingStream { continuation in
        let registration = document.addSnapshotListener { snapshot, error in
            if let error {
                continuation.finish(throwing: error)
            } else if let snapshot {
                do {
                    continuation.yield(try map(snapshot))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        let handle = ListenerRegistrationHandle(registration: registration)
        continuation.onTermination = { _ in
            handle.registration.remove()
        }
    }
}

/// Firestore's registration is only ever handed back to Firestore to remove the listener.
private struct ListenerRegistrationHandle: @unchecked Sendable {
    let registration: ListenerRegistration
}

extension Firestore {
    func privateDocument(_ name: String, of uid: String) -> DocumentReference {
        collection("users").document(uid).collection("private").document(name)
    }

    func shareDocument(recipient: String, sender: String) -> DocumentReference {
        collection("inboxes").document(recipient).collection("shares").document(sender)
    }
}
