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

import java.io.FileDescriptor;
import java.io.IOException;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.Socket;
import java.net.URL;
import java.net.URLConnection;
import java.net.UnknownHostException;

import javax.net.SocketFactory;

/**
 * Identifies a {@code Network}.
 * <p>
 * This is a desktop compatibility stub for the Android API 30 class. The pinned
 * {@code com.github.Suwayomi:android-jar} artifact no longer ships this class (it was
 * filtered out because a previous upstream source tree provided an implementation), so
 * the JVM build needs its own copy. Only identity and host resolution are implemented;
 * socket binding requires a real Android kernel and throws like the other stubs in this
 * package.
 */
public class Network implements Parcelable {
    private static final long HANDLE_MAGIC = 0xcafed00dL;
    private static final int HANDLE_MAGIC_SIZE = 32;

    /** The netId of this network, or {@code 0} if unknown. */
    public final int netId;

    /** @hide */
    public Network(int netId) {
        this.netId = netId;
    }

    /** @hide */
    public Network(Network that) {
        this(that.netId);
    }

    /**
     * Resolves the given host name against this network.
     */
    public InetAddress[] getAllByName(String host) throws UnknownHostException {
        return InetAddress.getAllByName(host);
    }

    /**
     * Resolves the given host name against this network.
     */
    public InetAddress getByName(String host) throws UnknownHostException {
        return InetAddress.getByName(host);
    }

    /** @hide */
    public int getNetId() {
        return netId;
    }

    public SocketFactory getSocketFactory() {
        throw new RuntimeException("Stub!");
    }

    public URLConnection openConnection(URL url) throws IOException {
        throw new RuntimeException("Stub!");
    }

    /** @hide */
    public URLConnection openConnection(URL url, Proxy proxy) throws IOException {
        throw new RuntimeException("Stub!");
    }

    public void bindSocket(DatagramSocket socket) throws IOException {
        throw new RuntimeException("Stub!");
    }

    public void bindSocket(Socket socket) throws IOException {
        throw new RuntimeException("Stub!");
    }

    /** @hide */
    public void bindSocket(FileDescriptor fd) throws IOException {
        throw new RuntimeException("Stub!");
    }

    /** @hide */
    public static Network fromNetworkHandle(long networkHandle) {
        if (networkHandle == 0) {
            throw new IllegalArgumentException("Network handle is zero.");
        }
        if ((int) (networkHandle & 0xffffffffL) != HANDLE_MAGIC) {
            throw new IllegalArgumentException("Bad magic in network handle.");
        }
        return new Network((int) (networkHandle >> HANDLE_MAGIC_SIZE));
    }

    public long getNetworkHandle() {
        if (netId == 0) {
            return 0L;
        }
        return ((long) netId << HANDLE_MAGIC_SIZE) | HANDLE_MAGIC;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
        dest.writeInt(netId);
    }

    public static final Parcelable.Creator<Network> CREATOR =
            new Parcelable.Creator<Network>() {
                @Override
                public Network createFromParcel(Parcel in) {
                    return new Network(in.readInt());
                }

                @Override
                public Network[] newArray(int size) {
                    return new Network[size];
                }
            };

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof Network)) {
            return false;
        }
        return netId == ((Network) obj).netId;
    }

    @Override
    public int hashCode() {
        return netId;
    }

    @Override
    public String toString() {
        return "Network " + netId;
    }
}
