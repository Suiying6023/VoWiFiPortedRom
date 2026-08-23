package com.voxi.minqns;

import android.telephony.AccessNetworkConstants;
import android.telephony.data.ApnSetting;
import android.telephony.data.QualifiedNetworksService;
import android.util.Log;

import java.util.Arrays;
import java.util.List;

/**
 * Minimal QNS for the VOXI/K50U WFC experiment.
 *
 * Goal: force the framework to consider IWLAN qualified for the IMS APN, so the
 * Qualcomm modem actually starts IKE/ePDG on the WiFi path instead of staying on WWAN.
 *
 * The framework serializes onCreateNetworkAvailabilityProvider() and the subsequent
 * registerForQualifiedNetworkTypesChanged() on one handler thread, and it replays
 * whatever is already in mQualifiedNetworkTypesList once the callback is registered.
 * So reporting from the constructor does reach telephony. We still re-report on a
 * timer, because MIUI SmartPower freezes this process and a later re-report both
 * survives that and gives us a timestamped log line proving the report happened.
 */
public class MinQnsService extends QualifiedNetworksService {
    private static final String TAG = "MinQns";

    /** Re-report every 30s so a missed/raced first report self-heals. */
    private static final long REPORT_INTERVAL_MS = 30_000L;

    @Override
    public NetworkAvailabilityProvider onCreateNetworkAvailabilityProvider(int slotIndex) {
        Log.i(TAG, "onCreateNetworkAvailabilityProvider slot=" + slotIndex);
        return new MinQnsProvider(slotIndex);
    }

    private class MinQnsProvider extends NetworkAvailabilityProvider {
        private final Thread mRepeater;
        private volatile boolean mClosed;

        MinQnsProvider(int slotIndex) {
            super(slotIndex);
            report("constructor");

            mRepeater = new Thread(new Runnable() {
                @Override
                public void run() {
                    int n = 0;
                    while (!mClosed) {
                        try {
                            Thread.sleep(REPORT_INTERVAL_MS);
                        } catch (InterruptedException e) {
                            return;
                        }
                        if (mClosed) return;
                        report("repeat#" + (++n));
                    }
                }
            }, "MinQnsRepeater");
            mRepeater.setDaemon(true);
            mRepeater.start();
        }

        /** Report IMS -> [IWLAN] only, so the framework cannot fall back to cellular. */
        private void report(String why) {
            List<Integer> qualified =
                    Arrays.asList(AccessNetworkConstants.AccessNetworkType.IWLAN);
            Log.i(TAG, "report(" + why + ") slot=" + getSlotIndex()
                    + " IMS(" + ApnSetting.TYPE_IMS + ") -> IWLAN("
                    + AccessNetworkConstants.AccessNetworkType.IWLAN + ")");
            updateQualifiedNetworkTypes(ApnSetting.TYPE_IMS, qualified);
        }

        @Override
        public void close() {
            mClosed = true;
            if (mRepeater != null) mRepeater.interrupt();
            Log.i(TAG, "provider close slot=" + getSlotIndex());
        }
    }
}
