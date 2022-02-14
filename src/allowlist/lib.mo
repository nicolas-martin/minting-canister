import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Prim "mo:prim";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";

import AccountIdentifier "mo:principal/AccountIdentifier";
import Ext "mo:ext/Ext";

import Allowlist "Allowlist";
import NNS "../NNS/lib";
import NNSTypes "../NNS/types";
import Types "types";


module {


    public let lockTtl = 300_000_000_000;  // Time for a transaction to complete (5 mins.)

    public class Factory (state : Types.State) {


        ////////////
        // State //
        //////////

        var nextTxId : Types.TxId = 0;
        public let purchases = HashMap.HashMap<Types.TxId, Types.Purchase>(
            state.purchases.size(),
            Nat32.equal,
            func (a) { a },
        );
        public let locks = HashMap.HashMap<Types.TxId, Types.Lock>(
            state.purchases.size(),
            Nat32.equal,
            func (a) { a },
        );

        private var pricePublicE8s : Nat64 = state.pricePublicE8s;
        private var pricePrivateE8s : Nat64 = state.pricePrivateE8s;

        // TODO: make this configurable

        public var presale = true;
        public var allowlist = HashMap.HashMap<Types.AccountIdentifier, Nat8>(
            state.allowlist.size(),
            AccountIdentifier.equal,
            AccountIdentifier.hash,
        );

        // Pre Upgrade

        public func toStable () : {
            nextTxId    : Types.TxId;
            locks       : [(Types.TxId, Types.Lock)];
            purchases   : [(Types.TxId, Types.Purchase)];
            allowlist   : [(Types.AccountIdentifier, Nat8)];
            pricePrivateE8s : Nat64;
            pricePublicE8s : Nat64;
        } {
            {
                nextTxId;
                locks       = Iter.toArray(locks.entries());
                purchases   = Iter.toArray(purchases.entries());
                allowlist   = Iter.toArray(allowlist.entries());
                pricePrivateE8s;
                pricePublicE8s;
            }
        };

        // Post Upgrade

        private func _restore (
            backup : {
                nextTxId    : ?Types.TxId;
                locks       : ?[(Types.TxId, Types.Lock)];
                purchases   : ?[(Types.TxId, Types.Purchase)];
                allowlist   : ?[(Types.AccountIdentifier, Nat8)];
                pricePrivateE8s : ?Nat64;
                pricePublicE8s : ?Nat64;
            }
        ) : () {
            switch (backup.nextTxId) {
                case (?x) nextTxId := x;
                case _ ();
            };
            
            switch (backup.pricePrivateE8s) {
                case (?x) pricePrivateE8s := x;
                case _ ();
            };
            
            switch (backup.pricePublicE8s) {
                case (?x) pricePublicE8s := x;
                case _ ();
            };

            switch (backup.locks) {
                case (?x) {
                    for ((k, v) in Iter.fromArray(x)) {
                        if (Time.now() < (v.lockedAt + lockTtl)) {
                            locks.put(k, v);
                        }
                    };
                };
                case _ ();
            };

            switch (backup.purchases) {
                case (?x) for ((k, v) in Iter.fromArray(x)) purchases.put(k, v);
                case _ ();
            };

            switch (backup.allowlist) {
                case (?x) for ((k, v) in Iter.fromArray(x)) allowlist.put(k, v);
                case _ ();
            }
        };

        public func restore (
            caller : Principal,
            backup : {
                nextTxId    : ?Types.TxId;
                locks       : ?[(Types.TxId, Types.Lock)];
                purchases   : ?[(Types.TxId, Types.Purchase)];
                allowlist  : ?[(Types.AccountIdentifier, Nat8)];
                pricePrivateE8s : ?Nat64;
                pricePublicE8s : ?Nat64;
            }
        ) : () {
            assert(state._Admins._isAdmin(caller));
            _restore(backup);
        };

        _restore({
            nextTxId = ?state.nextTxId;
            locks = ?state.locks;
            purchases = ?state.purchases;
            allowlist = ?state.allowlist;
            pricePrivateE8s = ?state.pricePrivateE8s;
            pricePublicE8s = ?state.pricePublicE8s;
        });


        ///////////////////////
        // Utils / Internal //
        /////////////////////


        // Get current price.
        public func _getPrice () : Nat64 {
            if (presale) {
                pricePrivateE8s;
            } else {
                pricePublicE8s;
            }
        };

        // Uppercase a string
        public func _upper (
            string : Text,
        ) : Text { Text.map(string, Prim.charToUpper); };

        // Get all valid locks.
        public func _getValidLocks () : [Nat32] {
            Array.map<(Types.TxId, Types.Lock), Nat32>(
                Array.filter<(Types.TxId, Types.Lock)>(
                    Iter.toArray(locks.entries()),
                    func (_, a) {
                        Time.now() < (a.lockedAt + lockTtl)
                    }
                ),
                func (_, x) {
                    x.token;
                }
            );
        };

        // Get lock for a user.
        public func _findLock (
            caller  : Principal,
        ) : ?Types.Lock {
            switch (
                Array.find<(Types.TxId, Types.Lock)>(
                    Iter.toArray<(Types.TxId, Types.Lock)>(locks.entries()),
                    func (_, a) {
                        a.buyer == caller
                    }
                )
            ) {
                case (?(_, lock)) ?lock;
                case _ null;
            }
        };

        // Get lock for a user and memo.
        public func _findLockWithMemo (
            caller  : Principal,
            memo    : Nat64,
        ) : ?Types.Lock {
            switch (
                Array.find<(Types.TxId, Types.Lock)>(
                    Iter.toArray<(Types.TxId, Types.Lock)>(locks.entries()),
                    func (_, a) {
                        a.memo == memo and a.buyer == caller
                    }
                )
            ) {
                case (?(_, lock)) ?lock;
                case _ null;
            }
        };

        // it seems to 
        // Find a purchase with a principal.
        public func _findPurchase (
            caller  : Principal,
            memo    : Nat64,
            height  : NNSTypes.BlockHeight,
        ) : ?Types.Purchase {
            switch (
                Array.find<(Types.TxId, Types.Purchase)>(
                    Iter.toArray<(Types.TxId, Types.Purchase)>(purchases.entries()),
                    func (_, a) {
                        a.memo == memo and a.buyer == caller and a.blockheight == height
                    }
                )
            ) {
                case (?(_, purchase)) ?purchase;
                case _ null;
            }
        };

        // Find a purchase with an account address.
        public func _findAccountPurchase (
            caller  : Text,
            memo    : Nat64,
            height  : NNSTypes.BlockHeight,
        ) : ?Types.Purchase {
            switch (
                Array.find<(Types.TxId, Types.Purchase)>(
                    Iter.toArray<(Types.TxId, Types.Purchase)>(purchases.entries()),
                    func (_, a) {
                        a.memo == memo and _upper(a.buyerAccount) == _upper(caller) and a.blockheight == height
                    }
                )
            ) {
                case (?(_, purchase)) ?purchase;
                case _ null;
            }
        };

        public func configurePrice (
            caller          : Principal,
            privatePriceE8s : Nat64,
            publicPriceE8s  : Nat64,
        ) : () {
            assert(state._Admins._isAdmin(caller));
            pricePrivateE8s := privatePriceE8s;
            pricePublicE8s  := publicPriceE8s;
        };


        /////////////////
        // Public API //
        ///////////////


        // Request a lock on a random unclaimed NFT for purchase.
        public func lock (
            caller  : Principal,
            memo    : Nat64,
        ) : async Result.Result<Types.TxId, Text> {
            // allowlistAccount contains an account if the presale is active and
            // the caller is in the allowlist.
            let allowlistAccount : ?Types.AccountIdentifier = if (presale) {
                switch (Allowlist.isInAllowlist(caller, allowlist)) {
                    // Return error if presale is active and caller is not allowed.
                    case (null)  return #err("Not in presale allowlist.");
                    case (? aId) ?aId;
                };
            } else { null };

            // Permit a single lock per principal.
            // TODO: Could this result in critical lost transaction state?
            switch (_findLock(caller)) {
                case (?lock) {
                    locks.delete(lock.id);
                };
                case _ ();
            };
            switch (state._Tokens._getNextMintIndex()) {
                case (?token) {
                    let txId = nextTxId;
                    nextTxId += 1;
                    locks.put(txId, {
                        id          = txId;
                        buyer       = caller;
                        buyerAccount= NNS.defaultAccount(caller);
                        lockedAt    = Time.now();
                        token;
                        memo;
                    });
                    #ok(txId);
                };
                case _ #err("No tokens left to mint.");
            };
        };

        // Poll for purchase completion.
        public func notify (
            caller      : Principal,
            blockheight : NNSTypes.BlockHeight,
            memo        : Nat64,
            canister    : Principal,
        ) : async Result.Result<Ext.TokenIndex, Text> {
            let price = _getPrice();
            switch (await state._Nns.block(blockheight)) {
                case (#Ok(block)) {
                    switch (block) {
                        case (#Err(_)) return #err("Some kind of block error");
                        case (#Ok(b)) {
                            if (b.transaction.memo != memo) {
                                return #err("Memo mismatch: " # Nat64.toText(memo) # ", " # Nat64.toText(b.transaction.memo));
                            };
                            switch (b.transaction.transfer) {
                                case (#Send(transfer)) {
                                    if (
                                        NNS.defaultAccount(canister) != _upper(transfer.to)
                                    ) {
                                        return #err("Incorrect transfer recipient: " # NNS.defaultAccount(canister) # ", " # _upper(transfer.to));
                                    } else if (
                                        NNS.defaultAccount(caller) != _upper(transfer.from)
                                    ) {
                                        return #err("Incorrect transfer sender: " # NNS.defaultAccount(caller) # ", " # _upper(transfer.from));
                                    } else if (transfer.amount.e8s < price) {
                                        return #err("Incorrect transfer amount.");
                                    };
                                    switch (_findLockWithMemo(caller, b.transaction.memo)) {
                                        case (?lock) {
                                            purchases.put(lock.id, {
                                                id          = lock.id;
                                                buyer       = lock.buyer;
                                                buyerAccount= NNS.defaultAccount(lock.buyer);
                                                token       = lock.token;
                                                memo        = lock.memo;
                                                price       = transfer.amount.e8s;
                                                lockedAt    = lock.lockedAt;
                                                closedAt    = Time.now();
                                                blockheight = blockheight;
                                            });
                                            locks.delete(lock.id);
                                            switch (
                                                state._Tokens._mint(
                                                    lock.token,
                                                    #principal(lock.buyer),
                                                    null,
                                                    // TODO: GET SUBACCOUNT
                                                    // switch (notification.from_subaccount) {
                                                    //     case (?sa) ?Blob.toArray(sa);
                                                    //     case _ null;
                                                    // }
                                                )
                                            ) {
                                                case (#ok(_)) {
                                                    let allowlistAccount : ?Types.AccountIdentifier = if (presale) {
                                                        switch (Allowlist.isInAllowlist(caller, allowlist)) {
                                                            // Return error if presale is active and caller is not allowed.
                                                            case (null)  return #err("Not in presale allowlist.");
                                                            case (? aId) ?aId;
                                                        };
                                                    } else { null };
                                                    // Mint was successful, so we can remove allowlist entry.
                                                    switch (allowlistAccount) {
                                                        case (? aId) Allowlist.consumeAllowlist(aId, allowlist);
                                                        case (_) {} // Not presale, nothing to do there.
                                                    };
                                                    // Insert transaction history event.
                                                    ignore await state._Cap.insert({
                                                        caller;
                                                        operation = "mint";
                                                        details = [
                                                            ("token", #Text(state._Tokens.tokenId(state.cid, lock.token))),
                                                            ("to", #Text(lock.buyerAccount)),
                                                            ("price_decimals", #U64(8)),
                                                            ("price_currency", #Text("ICP")),
                                                            ("price", #U64(price)),
                                                        ];
                                                    });
                                                    #ok(lock.token);
                                                };
                                                case (#err(_)) #err("Failed to mint.");
                                            };
                                        };
                                        case _ return #err("No such lock.");
                                    }
                                };
                                case (#Burn(_)) return #err("Incorrect transaction type.");
                                case (#Mint(_)) return #err("Incorrect transaction type.");
                            };
                        };
                    };
                };
                case (#Err(e)) return #err("Block lookup error: (" # Nat64.toText(blockheight) # ") " # e);
            };
        };

        public func getPrice () : Nat64 {
            _getPrice();
        };

        public func available () : Nat {
            state._Tokens._getUnminted().size();
        };


        ///////////////////
        // Internal API //
        /////////////////

        //


        ////////////////
        // Admin API //
        //////////////


    };
};
