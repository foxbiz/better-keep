import {
	type CallableFunction,
	type CallableOptions,
	type CallableRequest,
	onCall,
} from "firebase-functions/v2/https";
import { requireNonReviewAccess } from "./reviewAccess";

export type AuthenticatedCallableRequest<T> = CallableRequest<T> & {
	auth: NonNullable<CallableRequest<T>["auth"]>;
};

type ProtectedHandler<T, Return> = (
	request: AuthenticatedCallableRequest<T>,
) => Return;

export function withNonReviewAccess<T, Return>(
	handler: ProtectedHandler<T, Return>,
): (request: CallableRequest<T>) => Return {
	return (request) => {
		requireNonReviewAccess(request.auth);
		return handler(request as AuthenticatedCallableRequest<T>);
	};
}

export function onNonReviewCall<T = unknown, Return = unknown>(
	handler: ProtectedHandler<T, Return>,
): CallableFunction<
	T,
	Return extends Promise<unknown> ? Return : Promise<Return>
>;
export function onNonReviewCall<T = unknown, Return = unknown>(
	options: CallableOptions,
	handler: ProtectedHandler<T, Return>,
): CallableFunction<
	T,
	Return extends Promise<unknown> ? Return : Promise<Return>
>;
export function onNonReviewCall<T = unknown, Return = unknown>(
	optionsOrHandler: CallableOptions | ProtectedHandler<T, Return>,
	maybeHandler?: ProtectedHandler<T, Return>,
) {
	const handler =
		typeof optionsOrHandler === "function"
			? optionsOrHandler
			: (maybeHandler as ProtectedHandler<T, Return>);
	const wrapped = withNonReviewAccess(handler);
	return typeof optionsOrHandler === "function"
		? onCall(wrapped)
		: onCall(optionsOrHandler, wrapped);
}
