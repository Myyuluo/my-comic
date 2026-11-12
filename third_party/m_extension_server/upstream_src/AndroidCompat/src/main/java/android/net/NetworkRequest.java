/*
 * Copyright (C) 2014 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package android.net;

import android.os.Parcel;
import android.os.Parcelable;

import java.util.Objects;

/**
 * Defines a request for a network, made through
 * {@link ConnectivityManager#requestNetwork} or
 * {@link ConnectivityManager#registerNetworkCallback}.
 * <p>
 * This is a desktop compatibility stub for the Android API 30 class. The pinned
 * {@code com.github.Suwayomi:android-jar} artifact does not contain it, so the JVM
 * build provides an AOSP-shaped implementation. See {@link NetworkCapabilities} for
 * the capabilities actually matched by the desktop compatibility layer.
 */
public class NetworkRequest implements Parcelable {
    /**
     * The {@link NetworkCapabilities} that define this request.
     */
    public final NetworkCapabilities networkCapabilities;

    /**
     * Identifies the request.
     */
    public final int requestId;

    /**
     * Set for legacy requests and the default. Set to
     * {@link ConnectivityManager#TYPE_NONE} for none.
     */
    public final int legacyType;

    /**
     * The type of the request. This is only used by the system and is always NONE
     * elsewhere.
     */
    public final Type type;

    /**
     * A NetworkRequest as used by the system can be one of the following types.
     */
    public enum Type {
        NONE,
        LISTEN,
        TRACK_DEFAULT,
        REQUEST,
        BACKGROUND_REQUEST,
    }

    /** @hide */
    public NetworkRequest(NetworkCapabilities nc, int legacyType, int rId, Type type) {
        if (nc == null) {
            throw new NullPointerException();
        }
        this.requestId = rId;
        this.networkCapabilities = nc;
        this.legacyType = legacyType;
        this.type = type;
    }

    /** @hide */
    public NetworkRequest(NetworkRequest that) {
        this.networkCapabilities = new NetworkCapabilities(that.networkCapabilities);
        this.requestId = that.requestId;
        this.legacyType = that.legacyType;
        this.type = that.type;
    }

    /**
     * Builder used to create {@link NetworkRequest} objects. Specify the Network
     * features needed in terms of {@link NetworkCapabilities} features.
     */
    public static class Builder {
        private final NetworkCapabilities mNetworkCapabilities = new NetworkCapabilities();

        /**
         * Default constructor for Builder.
         */
        public Builder() {
        }

        /**
         * Build {@link NetworkRequest} with the current set of capabilities.
         */
        public NetworkRequest build() {
            return new NetworkRequest(
                    new NetworkCapabilities(mNetworkCapabilities),
                    ConnectivityManager.TYPE_NONE,
                    ConnectivityManager.REQUEST_ID_UNSET,
                    Type.NONE);
        }

        public Builder addCapability(int capability) {
            mNetworkCapabilities.addCapability(capability);
            return this;
        }

        public Builder removeCapability(int capability) {
            mNetworkCapabilities.removeCapability(capability);
            return this;
        }

        /** @hide */
        public Builder setCapabilities(NetworkCapabilities nc) {
            mNetworkCapabilities.set(nc);
            return this;
        }

        /** @hide */
        public Builder addUnwantedCapability(int capability) {
            mNetworkCapabilities.addUnwantedCapability(capability);
            return this;
        }

        public Builder clearCapabilities() {
            mNetworkCapabilities.clearAll();
            return this;
        }

        public Builder addTransportType(int transportType) {
            mNetworkCapabilities.addTransportType(transportType);
            return this;
        }

        public Builder removeTransportType(int transportType) {
            mNetworkCapabilities.removeTransportType(transportType);
            return this;
        }

        public Builder setLinkUpstreamBandwidthKbps(int upKbps) {
            mNetworkCapabilities.setLinkUpstreamBandwidthKbps(upKbps);
            return this;
        }

        public Builder setLinkDownstreamBandwidthKbps(int downKbps) {
            mNetworkCapabilities.setLinkDownstreamBandwidthKbps(downKbps);
            return this;
        }

        public Builder setNetworkSpecifier(String networkSpecifier) {
            throw new RuntimeException("Stub!");
        }

        public Builder setNetworkSpecifier(NetworkSpecifier networkSpecifier) {
            mNetworkCapabilities.setNetworkSpecifier(networkSpecifier);
            return this;
        }

        public Builder setSignalStrength(int signalStrength) {
            mNetworkCapabilities.setSignalStrength(signalStrength);
            return this;
        }
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
        dest.writeInt(requestId);
        dest.writeInt(legacyType);
        dest.writeInt(type.ordinal());
        networkCapabilities.writeToParcel(dest, flags);
    }

    public static final Parcelable.Creator<NetworkRequest> CREATOR =
            new Parcelable.Creator<NetworkRequest>() {
                @Override
                public NetworkRequest createFromParcel(Parcel in) {
                    int requestId = in.readInt();
                    int legacyType = in.readInt();
                    Type type = Type.values()[in.readInt()];
                    NetworkCapabilities nc = NetworkCapabilities.CREATOR.createFromParcel(in);
                    return new NetworkRequest(nc, legacyType, requestId, type);
                }

                @Override
                public NetworkRequest[] newArray(int size) {
                    return new NetworkRequest[size];
                }
            };

    /** @hide */
    public boolean isListen() {
        return type == Type.LISTEN;
    }

    /** @hide */
    public boolean isRequest() {
        return isForegroundRequest() || isBackgroundRequest();
    }

    /** @hide */
    public boolean isForegroundRequest() {
        return type == Type.TRACK_DEFAULT || type == Type.REQUEST;
    }

    /** @hide */
    public boolean isBackgroundRequest() {
        return type == Type.BACKGROUND_REQUEST;
    }

    public boolean hasCapability(int capability) {
        return networkCapabilities.hasCapability(capability);
    }

    /** @hide */
    public boolean hasUnwantedCapability(int capability) {
        return networkCapabilities.hasUnwantedCapability(capability);
    }

    /** @hide */
    public boolean canBeSatisfiedBy(NetworkCapabilities nc) {
        return networkCapabilities.satisfiedByNetworkCapabilities(nc);
    }

    public boolean hasTransport(int transportType) {
        return networkCapabilities.hasTransport(transportType);
    }

    public NetworkSpecifier getNetworkSpecifier() {
        return networkCapabilities.getNetworkSpecifier();
    }

    /** @hide */
    public int getRequestorUid() {
        return networkCapabilities.getRequestorUid();
    }

    /** @hide */
    public String getRequestorPackageName() {
        return networkCapabilities.getRequestorPackageName();
    }

    @Override
    public String toString() {
        return "NetworkRequest{requestId=" + requestId
                + ", legacyType=" + legacyType
                + ", type=" + type
                + ", capabilities=" + networkCapabilities
                + "}";
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof NetworkRequest)) {
            return false;
        }
        NetworkRequest that = (NetworkRequest) obj;
        return requestId == that.requestId
                && legacyType == that.legacyType
                && type == that.type
                && Objects.equals(networkCapabilities, that.networkCapabilities);
    }

    @Override
    public int hashCode() {
        return Objects.hash(networkCapabilities, requestId, legacyType, type);
    }
}
