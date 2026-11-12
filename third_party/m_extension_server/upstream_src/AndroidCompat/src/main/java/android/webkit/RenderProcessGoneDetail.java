/*
 * Copyright (C) 2017 The Android Open Source Project
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

package android.webkit;

/**
 * Represents the result of a renderer process crash.
 *
 * <p>This stub restores the framework class referenced by
 * {@link WebViewClient#onRenderProcessGone(WebView, RenderProcessGoneDetail)}
 * and by KCEF's renderer-termination callback. It was missing from the
 * vendored AndroidCompat source, so clean CI builds could not resolve it.
 */
public abstract class RenderProcessGoneDetail {
    /**
     * Indicates whether the renderer process crashed.
     *
     * @return {@code true} if the renderer process crashed, {@code false} if it was killed.
     */
    public abstract boolean didCrash();

    /**
     * Returns the priority of the renderer process at the time it exited.
     *
     * @return the renderer priority, or a negative value if unknown.
     */
    public abstract int rendererPriorityAtExit();
}
