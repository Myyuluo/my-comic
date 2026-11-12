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

import java.util.Arrays;
import java.util.Objects;

/**
 * Representation of the capabilities of an active network. Instances are typically
 * obtained through
 * {@link ConnectivityManager.NetworkCallback#onCapabilitiesChanged(Network, NetworkCapabilities)}
 * or {@link ConnectivityManager#getNetworkCapabilities(Network)}.
 * <p>
 * This is a desktop compatibility stub for the Android API 30 class. The pinned
 * {@code com.github.Suwayomi:android-jar} artifact does not contain it, so the JVM
 * build provides an AOSP-shaped implementation backed by the same bit masks used by
 * the real class.
 */
public final class NetworkCapabilities implements Parcelable {
    private static final int INVALID_UID = -1;

    /**
     * Represents the network's capabilities. If any are specified they will be
     * satisfied by any Network that matches all of them.
     */
    private long mNetworkCapabilities;

    /**
     * If any capabilities specified here they must not exist in the matching Network.
     */
    private long mUnwantedNetworkCapabilities;

    /**
     * Represents the transports of this network. If any are specified they will be
     * satisfied by any Network that matches all of them.
     */
    private int mTransportTypes;

    private int mLinkUpBandwidthKbps = LINK_BANDWIDTH_UNSPECIFIED;
    private int mLinkDownBandwidthKbps = LINK_BANDWIDTH_UNSPECIFIED;

    private NetworkSpecifier mNetworkSpecifier;
    private TransportInfo mTransportInfo;

    private int mSignalStrength = SIGNAL_STRENGTH_UNSPECIFIED;

    private int mOwnerUid = INVALID_UID;
    private int[] mAdministratorUids = new int[0];

    private String mSSID;
    private boolean mPrivateDnsBroken;

    private int mRequestorUid = INVALID_UID;
    private String mRequestorPackageName;

    // Capabilities.

    public static final int NET_CAPABILITY_MMS = 0;
    public static final int NET_CAPABILITY_SUPL = 1;
    public static final int NET_CAPABILITY_DUN = 2;
    public static final int NET_CAPABILITY_FOTA = 3;
    public static final int NET_CAPABILITY_IMS = 4;
    public static final int NET_CAPABILITY_CBS = 5;
    public static final int NET_CAPABILITY_WIFI_P2P = 6;
    public static final int NET_CAPABILITY_IA = 7;
    public static final int NET_CAPABILITY_RCS = 8;
    public static final int NET_CAPABILITY_XCAP = 9;
    public static final int NET_CAPABILITY_EIMS = 10;
    public static final int NET_CAPABILITY_NOT_METERED = 11;
    public static final int NET_CAPABILITY_INTERNET = 12;
    public static final int NET_CAPABILITY_NOT_RESTRICTED = 13;
    public static final int NET_CAPABILITY_TRUSTED = 14;
    public static final int NET_CAPABILITY_NOT_VPN = 15;
    public static final int NET_CAPABILITY_VALIDATED = 16;
    public static final int NET_CAPABILITY_CAPTIVE_PORTAL = 17;
    public static final int NET_CAPABILITY_NOT_ROAMING = 18;
    public static final int NET_CAPABILITY_FOREGROUND = 19;
    public static final int NET_CAPABILITY_NOT_CONGESTED = 20;
    public static final int NET_CAPABILITY_NOT_SUSPENDED = 21;
    public static final int NET_CAPABILITY_OEM_PAID = 22;
    public static final int NET_CAPABILITY_MCX = 23;
    public static final int NET_CAPABILITY_PARTIAL_CONNECTIVITY = 24;
    public static final int NET_CAPABILITY_TEMPORARILY_NOT_METERED = 25;

    // Transports.

    public static final int TRANSPORT_CELLULAR = 0;
    public static final int TRANSPORT_WIFI = 1;
    public static final int TRANSPORT_BLUETOOTH = 2;
    public static final int TRANSPORT_ETHERNET = 3;
    public static final int TRANSPORT_VPN = 4;
    public static final int TRANSPORT_WIFI_AWARE = 5;
    public static final int TRANSPORT_LOWPAN = 6;
    public static final int TRANSPORT_TEST = 7;

    private static final int MIN_TRANSPORT = TRANSPORT_CELLULAR;
    private static final int MAX_TRANSPORT = TRANSPORT_TEST;

    // Bandwidth and signal strength.

    public static final int LINK_BANDWIDTH_UNSPECIFIED = 0;
    public static final int SIGNAL_STRENGTH_UNSPECIFIED = Integer.MIN_VALUE;

    public NetworkCapabilities() {
        clearAll();
    }

    public NetworkCapabilities(NetworkCapabilities nc) {
        if (nc != null) {
            set(nc);
        }
    }

    /**
     * Completely clears the contents of this object, removing even the capabilities
     * that are set by default when the object is constructed.
     */
    public void clearAll() {
        mNetworkCapabilities = 0;
        mUnwantedNetworkCapabilities = 0;
        mTransportTypes = 0;
        mLinkUpBandwidthKbps = LINK_BANDWIDTH_UNSPECIFIED;
        mLinkDownBandwidthKbps = LINK_BANDWIDTH_UNSPECIFIED;
        mNetworkSpecifier = null;
        mTransportInfo = null;
        mSignalStrength = SIGNAL_STRENGTH_UNSPECIFIED;
        mOwnerUid = INVALID_UID;
        mAdministratorUids = new int[0];
        mSSID = null;
        mPrivateDnsBroken = false;
        mRequestorUid = INVALID_UID;
        mRequestorPackageName = null;
    }

    /**
     * Set all contents of this object to the contents of a NetworkCapabilities.
     */
    public void set(NetworkCapabilities nc) {
        if (nc == null) {
            clearAll();
            return;
        }
        mNetworkCapabilities = nc.mNetworkCapabilities;
        mUnwantedNetworkCapabilities = nc.mUnwantedNetworkCapabilities;
        mTransportTypes = nc.mTransportTypes;
        mLinkUpBandwidthKbps = nc.mLinkUpBandwidthKbps;
        mLinkDownBandwidthKbps = nc.mLinkDownBandwidthKbps;
        mNetworkSpecifier = nc.mNetworkSpecifier;
        mTransportInfo = nc.mTransportInfo;
        mSignalStrength = nc.mSignalStrength;
        mOwnerUid = nc.mOwnerUid;
        mAdministratorUids = nc.mAdministratorUids.clone();
        mSSID = nc.mSSID;
        mPrivateDnsBroken = nc.mPrivateDnsBroken;
        mRequestorUid = nc.mRequestorUid;
        mRequestorPackageName = nc.mRequestorPackageName;
    }

    private static void checkValidCapability(int capability) {
        if (capability < 0 || capability >= Long.SIZE) {
            throw new IllegalArgumentException("Capability must be in [0, 63]");
        }
    }

    private static void checkValidTransport(int transportType) {
        if (!isValidTransport(transportType)) {
            throw new IllegalArgumentException("Invalid transport " + transportType);
        }
    }

    public static boolean isValidTransport(int transportType) {
        return transportType >= MIN_TRANSPORT && transportType <= MAX_TRANSPORT;
    }

    private static int[] bitMaskToArray(long bits) {
        int[] result = new int[Long.bitCount(bits)];
        int index = 0;
        long remaining = bits;
        while (remaining != 0) {
            int bit = Long.numberOfTrailingZeros(remaining);
            result[index++] = bit;
            remaining &= remaining - 1;
        }
        return result;
    }

    private static long bitMaskFromArray(int[] capabilities) {
        long bits = 0;
        if (capabilities != null) {
            for (int capability : capabilities) {
                checkValidCapability(capability);
                bits |= 1L << capability;
            }
        }
        return bits;
    }

    public NetworkCapabilities addCapability(int capability) {
        checkValidCapability(capability);
        mNetworkCapabilities |= 1L << capability;
        return this;
    }

    public void addUnwantedCapability(int capability) {
        checkValidCapability(capability);
        mUnwantedNetworkCapabilities |= 1L << capability;
    }

    public NetworkCapabilities removeCapability(int capability) {
        checkValidCapability(capability);
        mNetworkCapabilities &= ~(1L << capability);
        return this;
    }

    public NetworkCapabilities setCapability(int capability, boolean value) {
        if (value) {
            addCapability(capability);
        } else {
            removeCapability(capability);
        }
        return this;
    }

    public int[] getCapabilities() {
        return bitMaskToArray(mNetworkCapabilities);
    }

    public int[] getUnwantedCapabilities() {
        return bitMaskToArray(mUnwantedNetworkCapabilities);
    }

    public void setCapabilities(int[] capabilities, int[] unwantedCapabilities) {
        mNetworkCapabilities = bitMaskFromArray(capabilities);
        mUnwantedNetworkCapabilities = bitMaskFromArray(unwantedCapabilities);
    }

    public void setCapabilities(int[] capabilities) {
        setCapabilities(capabilities, null);
    }

    public boolean hasCapability(int capability) {
        if (capability < 0 || capability >= Long.SIZE) {
            return false;
        }
        return (mNetworkCapabilities & (1L << capability)) != 0;
    }

    public boolean hasUnwantedCapability(int capability) {
        if (capability < 0 || capability >= Long.SIZE) {
            return false;
        }
        return (mUnwantedNetworkCapabilities & (1L << capability)) != 0;
    }

    public NetworkCapabilities addTransportType(int transportType) {
        checkValidTransport(transportType);
        mTransportTypes |= 1 << transportType;
        return this;
    }

    public NetworkCapabilities removeTransportType(int transportType) {
        checkValidTransport(transportType);
        mTransportTypes &= ~(1 << transportType);
        return this;
    }

    public NetworkCapabilities setTransportType(int transportType, boolean value) {
        if (value) {
            addTransportType(transportType);
        } else {
            removeTransportType(transportType);
        }
        return this;
    }

    public int[] getTransportTypes() {
        int[] result = new int[Integer.bitCount(mTransportTypes)];
        int index = 0;
        int remaining = mTransportTypes;
        while (remaining != 0) {
            int bit = Integer.numberOfTrailingZeros(remaining);
            result[index++] = bit;
            remaining &= remaining - 1;
        }
        return result;
    }

    public void setTransportTypes(int[] transportTypes) {
        mTransportTypes = 0;
        if (transportTypes != null) {
            for (int transportType : transportTypes) {
                addTransportType(transportType);
            }
        }
    }

    public boolean hasTransport(int transportType) {
        if (!isValidTransport(transportType)) {
            return false;
        }
        return (mTransportTypes & (1 << transportType)) != 0;
    }

    public NetworkCapabilities setLinkUpstreamBandwidthKbps(int upKbps) {
        mLinkUpBandwidthKbps = upKbps;
        return this;
    }

    public int getLinkUpstreamBandwidthKbps() {
        return mLinkUpBandwidthKbps;
    }

    public NetworkCapabilities setLinkDownstreamBandwidthKbps(int downKbps) {
        mLinkDownBandwidthKbps = downKbps;
        return this;
    }

    public int getLinkDownstreamBandwidthKbps() {
        return mLinkDownBandwidthKbps;
    }

    public static int minBandwidth(int a, int b) {
        if (a == LINK_BANDWIDTH_UNSPECIFIED) {
            return b;
        }
        if (b == LINK_BANDWIDTH_UNSPECIFIED) {
            return a;
        }
        return Math.min(a, b);
    }

    public static int maxBandwidth(int a, int b) {
        return Math.max(a, b);
    }

    public NetworkCapabilities setNetworkSpecifier(NetworkSpecifier networkSpecifier) {
        mNetworkSpecifier = networkSpecifier;
        return this;
    }

    public NetworkSpecifier getNetworkSpecifier() {
        return mNetworkSpecifier;
    }

    public NetworkCapabilities setTransportInfo(TransportInfo transportInfo) {
        mTransportInfo = transportInfo;
        return this;
    }

    public TransportInfo getTransportInfo() {
        return mTransportInfo;
    }

    public NetworkCapabilities setSignalStrength(int signalStrength) {
        mSignalStrength = signalStrength;
        return this;
    }

    public boolean hasSignalStrength() {
        return mSignalStrength > SIGNAL_STRENGTH_UNSPECIFIED;
    }

    public int getSignalStrength() {
        return mSignalStrength;
    }

    public NetworkCapabilities setOwnerUid(int uid) {
        mOwnerUid = uid;
        return this;
    }

    public int getOwnerUid() {
        return mOwnerUid;
    }

    public NetworkCapabilities setAdministratorUids(int[] administratorUids) {
        mAdministratorUids = administratorUids == null ? new int[0] : administratorUids.clone();
        return this;
    }

    public int[] getAdministratorUids() {
        return mAdministratorUids.clone();
    }

    public NetworkCapabilities setSSID(String ssid) {
        mSSID = ssid;
        return this;
    }

    public String getSsid() {
        return mSSID;
    }

    public NetworkCapabilities setRequestorUid(int uid) {
        mRequestorUid = uid;
        return this;
    }

    public int getRequestorUid() {
        return mRequestorUid;
    }

    public NetworkCapabilities setRequestorPackageName(String packageName) {
        mRequestorPackageName = packageName;
        return this;
    }

    public String getRequestorPackageName() {
        return mRequestorPackageName;
    }

    public boolean isMetered() {
        return !hasCapability(NET_CAPABILITY_NOT_METERED);
    }

    public boolean isPrivateDnsBroken() {
        return mPrivateDnsBroken;
    }

    public void setPrivateDnsBroken(boolean broken) {
        mPrivateDnsBroken = broken;
    }

    /**
     * Returns whether the given capabilities satisfy this set of requirements.
     */
    public boolean satisfiedByNetworkCapabilities(NetworkCapabilities nc) {
        if (nc == null) {
            return false;
        }
        // All required capabilities must be present in the candidate.
        if ((mNetworkCapabilities & ~nc.mNetworkCapabilities) != 0) {
            return false;
        }
        // None of the candidate's unwanted capabilities may be required here.
        if ((mUnwantedNetworkCapabilities & nc.mNetworkCapabilities) != 0) {
            return false;
        }
        // All required transports must be present in the candidate.
        return (mTransportTypes & ~nc.mTransportTypes) == 0;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof NetworkCapabilities)) {
            return false;
        }
        NetworkCapabilities that = (NetworkCapabilities) obj;
        return mNetworkCapabilities == that.mNetworkCapabilities
                && mUnwantedNetworkCapabilities == that.mUnwantedNetworkCapabilities
                && mTransportTypes == that.mTransportTypes
                && mLinkUpBandwidthKbps == that.mLinkUpBandwidthKbps
                && mLinkDownBandwidthKbps == that.mLinkDownBandwidthKbps
                && mSignalStrength == that.mSignalStrength
                && mOwnerUid == that.mOwnerUid
                && mPrivateDnsBroken == that.mPrivateDnsBroken
                && mRequestorUid == that.mRequestorUid
                && Objects.equals(mNetworkSpecifier, that.mNetworkSpecifier)
                && Objects.equals(mTransportInfo, that.mTransportInfo)
                && Objects.equals(mSSID, that.mSSID)
                && Objects.equals(mRequestorPackageName, that.mRequestorPackageName)
                && Arrays.equals(mAdministratorUids, that.mAdministratorUids);
    }

    @Override
    public int hashCode() {
        return Objects.hash(
                mNetworkCapabilities,
                mUnwantedNetworkCapabilities,
                mTransportTypes,
                mLinkUpBandwidthKbps,
                mLinkDownBandwidthKbps,
                mSignalStrength,
                mOwnerUid,
                mPrivateDnsBroken,
                mRequestorUid,
                mNetworkSpecifier,
                mTransportInfo,
                mSSID,
                mRequestorPackageName,
                Arrays.hashCode(mAdministratorUids));
    }

    @Override
    public String toString() {
        return "NetworkCapabilities{"
                + "capabilities=" + Arrays.toString(getCapabilities())
                + ", unwantedCapabilities=" + Arrays.toString(getUnwantedCapabilities())
                + ", transports=" + Arrays.toString(getTransportTypes())
                + ", linkUpBandwidthKbps=" + mLinkUpBandwidthKbps
                + ", linkDownBandwidthKbps=" + mLinkDownBandwidthKbps
                + ", signalStrength=" + mSignalStrength
                + ", networkSpecifier=" + mNetworkSpecifier
                + ", transportInfo=" + mTransportInfo
                + ", ssid=" + mSSID
                + "}";
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
        dest.writeLong(mNetworkCapabilities);
        dest.writeLong(mUnwantedNetworkCapabilities);
        dest.writeInt(mTransportTypes);
        dest.writeInt(mLinkUpBandwidthKbps);
        dest.writeInt(mLinkDownBandwidthKbps);
        dest.writeInt(mSignalStrength);
        dest.writeInt(mOwnerUid);
        dest.writeIntArray(mAdministratorUids);
        dest.writeString(mSSID);
        dest.writeInt(mPrivateDnsBroken ? 1 : 0);
        dest.writeInt(mRequestorUid);
        dest.writeString(mRequestorPackageName);
    }

    public static final Parcelable.Creator<NetworkCapabilities> CREATOR =
            new Parcelable.Creator<NetworkCapabilities>() {
                @Override
                public NetworkCapabilities createFromParcel(Parcel in) {
                    NetworkCapabilities nc = new NetworkCapabilities();
                    nc.mNetworkCapabilities = in.readLong();
                    nc.mUnwantedNetworkCapabilities = in.readLong();
                    nc.mTransportTypes = in.readInt();
                    nc.mLinkUpBandwidthKbps = in.readInt();
                    nc.mLinkDownBandwidthKbps = in.readInt();
                    nc.mSignalStrength = in.readInt();
                    nc.mOwnerUid = in.readInt();
                    int[] administratorUids = in.createIntArray();
                    nc.mAdministratorUids =
                            administratorUids == null ? new int[0] : administratorUids;
                    nc.mSSID = in.readString();
                    nc.mPrivateDnsBroken = in.readInt() != 0;
                    nc.mRequestorUid = in.readInt();
                    nc.mRequestorPackageName = in.readString();
                    return nc;
                }

                @Override
                public NetworkCapabilities[] newArray(int size) {
                    return new NetworkCapabilities[size];
                }
            };
}
