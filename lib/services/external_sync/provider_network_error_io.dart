import 'dart:io';

bool isProviderNetworkError(Object error) => error is IOException;
