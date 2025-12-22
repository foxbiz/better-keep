import 'package:sqflite/sqflite.dart';

typedef ModelListener<T> = void Function(ModelEvent<T>);

class ModelEvent<T> {
  final String event;
  final T payload;

  const ModelEvent(this.event, this.payload);
}

class _ModelEmitter<T> {
  final Map<String, List<ModelListener<T>>> _listeners = {
    "created": <ModelListener<T>>[],
    "updated": <ModelListener<T>>[],
    "deleted": <ModelListener<T>>[],
    "changed": <ModelListener<T>>[],
  };

  List<ModelListener<T>> _ensure(String event) {
    return _listeners.putIfAbsent(event, () => <ModelListener<T>>[]);
  }

  void emit(String event, T payload) {
    final eventListeners = List<ModelListener<T>>.from(_ensure(event));
    final changedListeners = List<ModelListener<T>>.from(_ensure("changed"));
    final modelEvent = ModelEvent<T>(event, payload);

    for (final listener in eventListeners) {
      listener(modelEvent);
    }

    for (final listener in changedListeners) {
      listener(modelEvent);
    }
  }

  void on(String event, ModelListener<T> callback) {
    _ensure(event).add(callback);
  }

  void off(String event, ModelListener<T> callback) {
    _ensure(event).remove(callback);
  }

  void once(String event, ModelListener<T> callback) {
    void wrapper(ModelEvent<T> eventPayload) {
      off(event, wrapper);
      callback(eventPayload);
    }

    on(event, wrapper);
  }
}

abstract class ModelSchema<T extends BaseModel<T>> {
  Future<void> createTable(Database db);

  Future<void> upgradeTable(Database db, int oldVersion, int newVersion);

  Future<List<T>> get(List<dynamic> args);
}

abstract class BaseModel<T extends BaseModel<T>> {
  int? id;
  BaseModel({this.id});

  static final Map<Type, _ModelEmitter<dynamic>> _emitters = {};
  static final Map<Type, ModelSchema<dynamic>> _schemas = {};

  static _ModelEmitter<T> _emitterFor<T>() {
    return _emitters.putIfAbsent(T, () => _ModelEmitter<T>())
        as _ModelEmitter<T>;
  }

  static void registerSchema<T extends BaseModel<T>>(ModelSchema<T> schema) {
    _schemas[T] = schema;
  }

  static ModelSchema<T> schema<T extends BaseModel<T>>() {
    final schema = _schemas[T];
    if (schema == null) {
      throw StateError("No schema registered for type $T");
    }

    return schema as ModelSchema<T>;
  }

  static Future<void> createTableFor<T extends BaseModel<T>>(Database db) {
    return schema<T>().createTable(db);
  }

  static Future<void> upgradeTableFor<T extends BaseModel<T>>(
    Database db,
    int oldVersion,
    int newVersion,
  ) {
    return schema<T>().upgradeTable(db, oldVersion, newVersion);
  }

  void notify(String event) async {
    BaseModel._emitterFor<T>().emit(event, this as T);
  }

  static void on<T>(String event, ModelListener<T> callback) {
    _emitterFor<T>().on(event, callback);
  }

  static void off<T>(String event, ModelListener<T> callback) {
    _emitterFor<T>().off(event, callback);
  }

  static void once<T>(String event, ModelListener<T> callback) {
    _emitterFor<T>().once(event, callback);
  }

  void sub(String event, ModelListener<T> callback) {
    BaseModel._emitterFor<T>().on(event, callback);
  }

  void unsub(String event, ModelListener<T> callback) {
    BaseModel._emitterFor<T>().off(event, callback);
  }

  void subonce(String event, ModelListener<T> callback) {
    BaseModel._emitterFor<T>().once(event, callback);
  }
}
