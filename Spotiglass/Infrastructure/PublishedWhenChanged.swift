import Combine

/// Like `@Published`, but setting the value it already has announces nothing.
///
/// `@Published` tells every observer of its object about each assignment, equal or not. The
/// playback session re-reads the player every few seconds and assigns shuffle, repeat, volume,
/// device and up-next again with the same values, and each of those re-rendered every view that
/// observes the session: the track list, the sidebar, the bar (#409).
///
/// For classes only, and the class must declare its own
/// `let objectWillChange = ObservableObjectPublisher()`. `$name` publishes each new value just
/// before it is stored, as `@Published` does.
@propertyWrapper
struct PublishedWhenChanged<Value: Equatable> {
    private var value: Value
    private let subject: CurrentValueSubject<Value, Never>

    init(wrappedValue: Value) {
        value = wrappedValue
        subject = CurrentValueSubject(wrappedValue)
    }

    @available(*, unavailable, message: "@PublishedWhenChanged is only available on properties of classes")
    var wrappedValue: Value {
        get { fatalError("unavailable") }
        set { fatalError("unavailable") } // swiftlint:disable:this unused_setter_value
    }

    var projectedValue: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }

    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { object[keyPath: storageKeyPath].value }
        set {
            guard object[keyPath: storageKeyPath].value != newValue else { return }
            object.objectWillChange.send()
            object[keyPath: storageKeyPath].subject.send(newValue)
            object[keyPath: storageKeyPath].value = newValue
        }
    }
}
