#!/usr/bin/env bash

## Run integrity check, to make sure that the context is valid

set -xe

if [ "$MODE" = "tezedge" ] || [ "$MODE" = "irmin" ]; then

    mount -o ro /dev/sdb "$MOUNT_PATH" || exit 0

    if [ "$MODE" = "tezedge" ]; then
        FILE="sizes.db"
    elif [ "$MODE" = "irmin" ]; then
        FILE="store.pack"
    fi

    ls -laR "$MOUNT_PATH" || true

    if [ ! -f "$CONTEXT_PATH/$FILE" ];then
        echo "Context does not exist"
        sleep 0.1s
        umount "$MOUNT_PATH"
        exit 0
    fi

    ls -laR "$CONTEXT_PATH/"

    rm -rf /tmp/context
    cp -r "$CONTEXT_PATH" /tmp/context

    cd /home/sebastien/github/tezedge
    # cd "$TEZEDGE_PATH" #TODO: Use this

    set +e

    RESULT=1
    if [ "$MODE" = "tezedge" ]; then
        "$TEZEDGE_PATH/target/release/context-tool" is-valid-context --context-path "$CONTEXT_PATH"
        RESULT=$?
    elif [ "$MODE" = "irmin" ]; then
        cargo test --release -p tezos_interop --test integrity_check -- --nocapture
        RESULT=$?
    fi

    set -e

    if [ $RESULT -gt 0 ]; then
        echo -n 1 >> /tmp/invalid_context
    else
        echo -n 1 >> /tmp/valid_context
    fi

    umount "$MOUNT_PATH" || true

else
    ## Bootstrap test

    btrfs check --readonly /dev/sdb

    mount -o ro /dev/sdb "$MOUNT_PATH" || exit 0

    if [ ! -f "$MOUNT_PATH/context/sizes.db" ];then
        echo "Context does not exist"
        sleep 0.1s
        umount "$MOUNT_PATH"
        exit 0
    fi

    rm -rf /tmp/tezos_dir
    mkdir -p /tmp/tezos_dir
    cp -r $MOUNT_PATH/* /tmp/tezos_dir/

    "$TEZEDGE_PATH/target/release/light-node" \
        --protocol-runner "$TEZEDGE_PATH/target/release/protocol-runner" \
        --tezos-data-dir /tmp/tezos_dir/ \
        --network="$NETWORK" \
        --bootstrap-db-path=bootstrap_db \
        --tezos-context-storage=tezedge \
        --p2p-port 19732 \
        --peers="127.0.0.1:9733" \
        --rpc-port=18733 \
        --config-file "$TEZEDGE_PATH/light_node/etc/tezedge/tezedge.config" &

    TPID=$!
    sleep 2s

    block=0
    previous_block=100000
    attempts=0
    while [ $attempts -lt 30 ]; do
        sleep 1s
        b=$(curl -s localhost:18733/chains/main/blocks/head | jq .header.level)
        block=${b:-$block}
        echo "===> ici Block level $block"
        if [ $block -gt $previous_block ]; then
            kill $TPID || true
            sleep 1s
            umount "$MOUNT_PATH" || true
            exit 0
        fi
        if [ $block -gt 0 ]; then
            previous_block=$block
        fi
        attempts=$(($attempts + 1))
    done

    kill $TPID || true
    sleep 10s
    umount "$MOUNT_PATH" || true
    exit 1
fi
