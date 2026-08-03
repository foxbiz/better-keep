import type { CallableRequest } from "firebase-functions/v2/https";
import { onCall } from "firebase-functions/v2/https";
import { redeemOAuthCompletion } from "../oauthCompletion";

interface RedeemOAuthCompletionRequest {
	code?: string;
	verifier?: string;
}

export default onCall(
	async (request: CallableRequest<RedeemOAuthCompletionRequest>) => {
		const customToken = await redeemOAuthCompletion({
			code: request.data?.code ?? "",
			verifier: request.data?.verifier ?? "",
		});
		return { customToken };
	},
);
